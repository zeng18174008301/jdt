import IM4Domain
import IM4Data
import UIKit
import IM4Core // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111
import Foundation
import Combine
import SwiftUI
import XCTest
@testable import WenDaTong

// WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_BEGIN
extension DomainStoreTests {
    // WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_BEGIN
    // WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111_BEGIN
    func testMountedChatEntryUsesNativeHistorySDKWorkerAndExactInstalledProjection() async throws {
        let messages = (1...50).map { computeMessage("native-history-\($0)", sequence: Int64($0)) }
        let body = try phase6Page(messages).data
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase6HistoryURLProtocol.self]
        let session = URLSession(configuration: config)
        Phase6HistoryURLProtocol.install(body)
        defer {
            session.invalidateAndCancel()
            Phase6HistoryURLProtocol.install(nil) // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
        }
        let suite = "phase6-mounted-history-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let f = try await phase6HTTPFixture(responses: [], transport: URLSessionHTTPTransport(session: session),
            isolatedDefaults: defaults)
        defer { f.close() }
        var row = computeRow("decode-channel", messageID: "initial")
        row.messages = []
        row.lastMsgSeq = 50
        row.messageCoveredThroughSeq = 0
        f.state.conversationStore.hydrateCachedConversations([row])
        _ = f.state.remoteSyncEngine.beginRemoteSnapshotRefresh()

        let observed = expectation(description: "current mounted Chat63 projection observed actual history")
        let recorder = Phase6NativeTraceRecorder(observed: observed)
        MessageDerivationInstrumentation.setEmissionObserver { recorder.record($0) }
        defer { MessageDerivationInstrumentation.setEmissionObserver(nil) }
        var computed: [RealtimeComputeRuntime.Observation] = []
        f.state.realtimeComputeRuntime.onComputed = { computed.append($0) }
        defer { f.state.realtimeComputeRuntime.onComputed = nil }
        let expectedIDs = (31...50).map { "native-history-\($0)" }
        let expectedSequences = (31...50).map(Int64.init)
        var installs: [(input: UInt64, output: UInt64, ids: [String], sequences: [Int64])] = []
        let commits = f.state.conversationStore.memoryCommits.sink { commit in
            guard let messages = commit.messageChanges[row.id]?.current,
                  messages.contains(where: { $0.id == "native-history-50" }) else { return }
            installs.append((commit.previous.revision, commit.current.revision, messages.map(\.id), messages.map(\.channelSeq)))
        }
        defer { commits.cancel() }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let size = CGRect(x: 0, y: 0, width: 390, height: 760)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: size)
        window.frame = size
        let host = UIHostingController(rootView: NavigationView {
            AppFeatureComposition.chatRouting().makeChat(row.id)
        }.navigationViewStyle(.stack).appStateEnvironment(f.state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [observed], timeout: 8)

        let events = recorder.snapshot()
        let samples = events.compactMap { event -> MessageDerivationSample? in
            if case .sample(let value) = event { return value }; return nil
        }
        let projection = try XCTUnwrap(samples.first { $0.phase == .projectionObserved })
        let chain = samples.filter { $0.context == projection.context }
        let source = try XCTUnwrap(projection.context.sourceCorrelations.first)
        XCTAssertEqual(projection.context.sourceCorrelations, [source])
        let http = samples.filter { $0.context.operation == source }
        XCTAssertEqual(http.map(\.phase), [.arrival, .decode])
        XCTAssertTrue(http.allSatisfy { !$0.onMainThread })
        XCTAssertNotEqual(projection.context.operation, source)
        let physicalProducers = events.compactMap { event -> UInt64? in
            guard case .sourceLink(let operation, let producer, "physical_source", 0) = event,
                  operation == source else { return nil }
            return producer
        }
        XCTAssertEqual(physicalProducers, [source])
        let semanticLinks = events.compactMap { event -> String? in
            guard case .sourceLink(let operation, let origin, let phase, _) = event,
                  operation == projection.context.operation, origin == source else { return nil }
            return phase
        }
        XCTAssertEqual(semanticLinks, chain.map { $0.phase.rawValue })
        XCTAssertEqual(chain.map(\.phase), [.queued, .references, .capture, .mapping, .merging, .ordering,
            .validation, .ready, .storeInstalled, .projectionObserved, .commit])
        let workerPhases: Set<MessageDerivationSample.Phase> = [.references, .mapping, .merging, .ordering]
        for sample in chain {
            XCTAssertEqual(sample.onMainThread, !workerPhases.contains(sample.phase), sample.phase.rawValue)
        }
        let timestamps = (http + chain).map(\.uptimeNanoseconds)
        XCTAssertGreaterThan(try XCTUnwrap(timestamps.first), 0)
        for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
            XCTAssertLessThan(earlier, later)
        }
        XCTAssertEqual(computed.count, 1)
        let observation = try XCTUnwrap(computed.first)
        XCTAssertEqual(observation.attempts, 1)
        XCTAssertEqual(observation.stalePlans, 0)
        XCTAssertFalse(observation.fallback)
        XCTAssertTrue(observation.fallbackReasons.isEmpty)

        let installation = try XCTUnwrap(chain.first { $0.phase == .storeInstalled })
        let frame = try XCTUnwrap(installation.outputRevision)
        XCTAssertEqual(projection.outputRevision, frame)
        XCTAssertEqual(installs.count, 1)
        let commit = try XCTUnwrap(installs.first)
        XCTAssertEqual(commit.input, installation.inputRevision)
        XCTAssertEqual(commit.output, frame)
        XCTAssertGreaterThan(frame, commit.input)
        XCTAssertEqual(commit.ids, expectedIDs)
        XCTAssertEqual(commit.sequences, expectedSequences)
        XCTAssertEqual(Phase6HistoryURLProtocol.requestCount, 1)
        // The server over-returns 50 fixture rows. Normal chat entry keeps the original latest window of 20.
        XCTAssertEqual(f.state.latestConversationMessageWindowLimit, 20)
        let windowMessages = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: row.id)?.messages)
        XCTAssertEqual(windowMessages.map(\.id), expectedIDs)
        XCTAssertEqual(windowMessages.map(\.channelSeq), expectedSequences)
        let frameEvidence = try JSONSerialization.data(withJSONObject: [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "fixtureRoot": f.root.path, "preferencesSuite": suite, "conversationID": row.id,
            "httpSource": source, "physicalProducers": physicalProducers,
            "workerOperation": projection.context.operation, "semanticLinks": semanticLinks,
            "inputRevision": commit.input, "installedRevision": commit.output,
            "observedRevision": frame, "messageIDs": commit.ids, "messageSequences": commit.sequences,
            "attempts": observation.attempts, "stalePlans": observation.stalePlans, "fallback": observation.fallback,
            "historyRequests": Phase6HistoryURLProtocol.requestCount
        ], options: [.sortedKeys])
        let receipt = XCTAttachment(data: frameEvidence, uniformTypeIdentifier: "public.json")
        receipt.name = "phase6-mounted-native-history-store-frame"
        receipt.lifetime = .keepAlways
        add(receipt)
        let trace = XCTAttachment(data: try JSONEncoder().encode(http + chain), uniformTypeIdentifier: "public.json")
        trace.name = "phase6-mounted-native-history50-actual-threads-and-frame"
        trace.lifetime = .keepAlways; add(trace)
        let environment = XCTAttachment(string: "scene=\(window.windowScene?.activationState.rawValue.description ?? "none"); app=\(UIApplication.shared.applicationState.rawValue); windowHidden=\(window.isHidden)")
        environment.name = "phase6-mounted-host-state"; environment.lifetime = .keepAlways; add(environment)
    }
    // WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111_END
    // WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_END

    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
    func testSnapshotSequenceRecoveryUsesTwoNativePagesAndMountedChat() async throws {
        let first = try recoveryPage([3, 2, 3], nextAfter: 3, hasMore: true)
        let second = try recoveryPage([5, 4, 3, 5], nextAfter: 5, hasMore: false)
        // WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112_BEGIN
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
        // WDT_IOS1_MOUNTED_RECOVERY_DEFAULTS_SUITE_20261112_BEGIN
        let suite = "phase6-mounted-recovery-" + UUID().uuidString
        let (f, recovery) = try await trackedRecoveryFixture(pages: [first, second], defaultsSuite: suite)
        // WDT_IOS1_MOUNTED_RECOVERY_DEFAULTS_SUITE_20261112_END
        defer { recovery.retire() }
        let row = try await seedSequenceRecovery(f)
        let entered = expectation(description: "first native page reached the recovery worker")
        recovery.suspendFirstMapping(entered)
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END
        // WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112_END
        var computed: [RealtimeComputeRuntime.Observation] = []
        f.state.realtimeComputeRuntime.onComputed = { computed.append($0) }
        let observed = expectation(description: "mounted Chat consumed a traced recovery frame")
        let recorder = Phase6NativeTraceRecorder(observed: observed)
        MessageDerivationInstrumentation.setEmissionObserver { recorder.record($0) }
        defer { MessageDerivationInstrumentation.setEmissionObserver(nil) }
        var installed: [UInt64] = []
        let commits = f.state.conversationStore.memoryCommits.sink { commit in
            guard let change = commit.messageChanges[row.id],
                  change.current.count > change.previous.count,
                  change.current.contains(where: { $0.id == "recovery-2" }) else { return }
            installed.append(commit.current.revision)
        }
        defer { commits.cancel() }

        let refreshed = await f.state.refreshRemoteSnapshot(silent: true)
        XCTAssertTrue(refreshed)
        await fulfillment(of: [entered], timeout: 4)
        XCTAssertEqual(Phase6HistoryURLProtocol.requestCount, 1, "next page waits for the first commit")
        XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: row.id)?.messages.map(\.id), ["base"])

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let size = CGRect(x: 0, y: 0, width: 390, height: 760)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: size)
        window.frame = size
        window.rootViewController = UIHostingController(rootView: NavigationView {
            AppFeatureComposition.chatRouting().makeChat(row.id)
        }.navigationViewStyle(.stack).appStateEnvironment(f.state))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        recovery.gate.release() // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112
        await fulfillment(of: [observed], timeout: 8)
        func traceSamples() -> [MessageDerivationSample] {
            recorder.snapshot().compactMap { event in
                if case .sample(let sample) = event { return sample }
                return nil
            }
        }
        for _ in 0..<200 {
            if installed.count == 2, traceSamples().contains(where: {
                $0.phase == .projectionObserved && $0.outputRevision == installed.last
            }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let samples = traceSamples()
        XCTAssertEqual(installed.count, 2)
        XCTAssertEqual(installed, installed.sorted())
        XCTAssertEqual(Set(installed).count, 2)
        let finalRevision = try XCTUnwrap(installed.last)
        let projection = try XCTUnwrap(samples.first { $0.phase == .projectionObserved && $0.outputRevision == finalRevision })
        XCTAssertTrue(projection.onMainThread)
        XCTAssertEqual(samples.first { $0.phase == .storeInstalled && $0.context == projection.context }?.outputRevision, finalRevision)
        let recoveryInstalls = samples.filter { $0.phase == .storeInstalled && !$0.context.sourceCorrelations.isEmpty }
        XCTAssertEqual(recoveryInstalls.compactMap(\.outputRevision), installed)
        for installation in recoveryInstalls {
            let chain = samples.filter { $0.context == installation.context }
            let source = try XCTUnwrap(installation.context.sourceCorrelations.first)
            let http = samples.filter { $0.context.operation == source }
            XCTAssertEqual(http.map(\.phase), [.arrival, .decode])
            XCTAssertTrue(http.allSatisfy { !$0.onMainThread })
            for phase: MessageDerivationSample.Phase in [.mapping, .merging, .ordering] {
                let stage = try XCTUnwrap(chain.first { $0.phase == phase })
                XCTAssertFalse(stage.onMainThread)
            }
        }
        XCTAssertEqual(computed.count, 2)
        XCTAssertTrue(computed.allSatisfy { !$0.fallback && !$0.mappedOnMainThread && !$0.mergedOnMainThread })
        XCTAssertEqual(Phase6HistoryURLProtocol.recoveryRequests.map(\.after), [1, 3])
        XCTAssertEqual(Phase6HistoryURLProtocol.recoveryRequests.map(\.limit), [100, 100])
        let result = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: row.id))
        XCTAssertEqual(result.messages.map(\.id), ["base", "recovery-2", "recovery-3", "recovery-4", "recovery-5"])
        XCTAssertEqual(result.messageCoveredThroughSeq, 5)
        // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
        // The mounted projection can precede the acknowledged SQLite write.
        for _ in 0..<200 where f.state.messageSequenceRecoveryTargets[row.id] != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END
        XCTAssertNil(f.state.messageSequenceRecoveryTargets[row.id])
        XCTAssertNil(f.state.messageSequenceRecoveryRetryTasks[row.id])
        let ticket = try XCTUnwrap(f.state.localMessageTicket)
        let expectedRevision = f.state.localMessageProjectionRevision
        var persisted = try await f.persistence.projectionRevisionFloor(ticket: ticket)
        for _ in 0..<200 where persisted < expectedRevision {
            try await Task.sleep(nanoseconds: 10_000_000)
            persisted = try await f.persistence.projectionRevisionFloor(ticket: ticket)
        }
        XCTAssertGreaterThanOrEqual(persisted, expectedRevision)
        let disk = try await f.persistence.activateAndLoad(context: f.state.apiContext,
            sessionGeneration: f.state.localMessageSessionGeneration)
        let diskRow = try XCTUnwrap(disk.conversations.first { $0.id == row.id })
        XCTAssertEqual(diskRow.messageCoveredThroughSeq, 5)
        XCTAssertEqual(diskRow.messages.map(\.id), result.messages.map(\.id))
        let trace = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
        trace.name = "sequence-recovery-native-two-pages-installed-and-mounted"
        trace.lifetime = .keepAlways
        add(trace)
    }

    func testSnapshotSequenceRecoveryRejectsSuspendedPageAfterBoundaryAdvances() async throws {
        let page = try recoveryPage([2, 3], nextAfter: 3, hasMore: true)
        // WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112_BEGIN
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
        let (f, recovery) = try await trackedRecoveryFixture(pages: [page])
        defer { recovery.retire() }
        let row = try await seedSequenceRecovery(f)
        let entered = expectation(description: "recovery worker suspended on original boundary")
        let rejected = expectation(description: "old recovery operation rejected")
        recovery.suspendFirstMapping(entered)
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END
        // WDT_IOS1_SEQUENCE_RECOVERY_PROBE_LIFETIME_20261112_END
        f.state.realtimeComputeRuntime.onDerivation = { samples in
            if samples.contains(where: { $0.phase == .rejected }) {
                XCTAssertFalse(samples.contains { $0.phase == .commit || $0.phase == .storeInstalled })
                rejected.fulfill()
            }
        }
        let refreshed = await f.state.refreshRemoteSnapshot(silent: true)
        XCTAssertTrue(refreshed)
        await fulfillment(of: [entered], timeout: 4)
        let prior = try XCTUnwrap(f.state.messageSequenceRecoveryTargets[row.id])
        let revision = f.state.conversationStore.memorySnapshot.revision
        XCTAssertNotNil(f.state.beginGroupHistoryBoundaryRequest(context: f.state.apiContext,
            channelID: row.id, channelType: "group"))
        recovery.gate.release() // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112
        await fulfillment(of: [rejected], timeout: 4)
        XCTAssertEqual(Phase6HistoryURLProtocol.recoveryRequests.map(\.after), [1])
        XCTAssertEqual(f.state.conversationStore.conversationMessageSnapshot(id: row.id)?.messages.map(\.id), ["base"])
        XCTAssertEqual(f.state.conversationStore.memorySnapshot.revision, revision)
        XCTAssertEqual(f.state.messageSequenceRecoveryTargets[row.id], prior)
        XCTAssertNil(f.state.messageSequenceRecoveryRetryTasks[row.id])
        XCTAssertFalse(f.state.conversationStore.isMessageSyncInFlight(historyKey: f.state.conversationHistoryStateKey(for: row)))
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
        await recovery.drain()
        try await checkRetirementWhileMappingRecoveryPage(page)
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END
    }

    // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
    func testSnapshotSequenceRecoveryRetriesRejectedProjectionAndReopensBothConversations() async throws {
        let channelA = "decode-channel", channelB = "recovery-second-channel"
        func page(channel: String, prefix: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
                "items": [Int64(3), 2, 3, 4, 5].map {
                    computeMessage("\(prefix)-\($0)", sequence: $0, channel: channel)
                },
                "next_after_seq": 5, "has_more_after": false
            ]])
        }
        let session = recoverySession(pages: [try page(channel: channelA, prefix: "repair-a"),
            try page(channel: channelB, prefix: "repair-b")])
        defer { Phase6HistoryURLProtocol.install(nil) }
        let f = try await phase6HTTPFixture(responses: [], transport: URLSessionHTTPTransport(session: session))
        defer { f.close() }
        let rowA = try await seedSequenceRecovery(f)
        var rowB = computeRow(channelB, messageID: "base-b")
        rowB.lastMsgSeq = 5
        rowB.messageCoverageRequiresRecovery = true
        let ticket = try XCTUnwrap(f.state.localMessageTicket)
        _ = try await f.persistence.persist(ticket: ticket, snapshots: [
            LocalMessageConversationSnapshot(conversation: rowB, channelID: channelB, channelType: "group",
                currentActorID: "actor-a")
        ], source: .history, revision: f.state.nextLocalMessageProjectionRevision())

        let entered = expectation(description: "A is suspended after reserving the SQLite projection revision")
        var heldA: CheckedContinuation<Void, Never>?
        var reservedA: [Int64] = []
        f.state.realtimeComputeRuntime.beforeRecoveryProjection = { id, revision in
            guard id == channelA else { return }
            reservedA.append(revision)
            if reservedA.count == 1 {
                await withCheckedContinuation { continuation in
                    heldA = continuation
                    entered.fulfill()
                }
            }
        }
        defer {
            heldA?.resume()
            f.state.realtimeComputeRuntime.beforeRecoveryProjection = nil
        }
        let refreshed = await f.state.refreshRemoteSnapshot(silent: true)
        XCTAssertTrue(refreshed)
        await fulfillment(of: [entered], timeout: 4)
        let firstA = try XCTUnwrap(reservedA.first)
        let appliedA = try XCTUnwrap(f.state.conversationStore.conversationMessageSnapshot(id: rowA.id))
        XCTAssertEqual(appliedA.messageCoveredThroughSeq, 5)
        XCTAssertNotNil(f.state.messageSequenceRecoveryTargets[rowA.id], "memory completion must not retire the target")
        f.state.conversationStore.hydrateCachedConversations([appliedA, rowB])
        f.state.schedulePersistedMessageSequenceRecoveries(reason: "contended_recovery_fixture")
        for _ in 0..<200 where f.state.messageSequenceRecoveryTargets[rowB.id] != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(f.state.messageSequenceRecoveryTargets[rowB.id])
        let floorBeforeA = try await f.persistence.projectionRevisionFloor(ticket: ticket)
        XCTAssertGreaterThan(floorBeforeA, firstA, "B committed above A's reserved revision")
        let intermediate = try await f.persistence.activateAndLoad(context: f.state.apiContext,
            sessionGeneration: f.state.localMessageSessionGeneration)
        XCTAssertEqual(intermediate.conversations.first(where: { $0.id == rowA.id })?.messageCoveredThroughSeq, 1)
        XCTAssertEqual(intermediate.conversations.first(where: { $0.id == rowB.id })?.messageCoveredThroughSeq, 5)

        let index = try XCTUnwrap(f.state.conversationStore.conversations.firstIndex { $0.id == rowA.id })
        f.state.conversationStore.mutateStoredConversation(at: index) { snapshot in
            if let row = snapshot.messages.firstIndex(where: { $0.id == "repair-a-2" }) {
                snapshot.messages[row].text = "Latest after B committed"
            }
        }
        let releaseA = try XCTUnwrap(heldA)
        heldA = nil
        releaseA.resume()
        for _ in 0..<200 where f.state.messageSequenceRecoveryTargets[rowA.id] != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(f.state.messageSequenceRecoveryTargets[rowA.id])
        XCTAssertNil(f.state.messageSequenceRecoveryRetryTasks[rowA.id])
        XCTAssertEqual(reservedA.count, 2, "one rejected write must reserve a fresh revision")
        XCTAssertGreaterThan(try XCTUnwrap(reservedA.last), floorBeforeA)
        XCTAssertEqual(Phase6HistoryURLProtocol.recoveryRequests.map(\.after), [1, 1])
        XCTAssertEqual(Phase6HistoryURLProtocol.recoveryRequests.map(\.limit), [100, 100])

        let reopened = MessagePersistenceCoordinator(applicationSupportBase: f.root.appendingPathComponent("support"),
            cachesBase: f.root.appendingPathComponent("caches"))
        let disk = try await reopened.activateAndLoad(context: f.state.apiContext,
            sessionGeneration: f.state.localMessageSessionGeneration)
        let savedA = try XCTUnwrap(disk.conversations.first { $0.id == rowA.id })
        let savedB = try XCTUnwrap(disk.conversations.first { $0.id == rowB.id })
        XCTAssertEqual(savedA.messageCoveredThroughSeq, 5)
        XCTAssertEqual(savedB.messageCoveredThroughSeq, 5)
        XCTAssertEqual(savedA.messages.map(\.id), ["base", "repair-a-2", "repair-a-3", "repair-a-4", "repair-a-5"])
        XCTAssertEqual(savedB.messages.map(\.id), ["base-b", "repair-b-2", "repair-b-3", "repair-b-4", "repair-b-5"])
        XCTAssertEqual(savedA.messages.first { $0.id == "repair-a-2" }?.text, "Latest after B committed")
        let evidence = try JSONSerialization.data(withJSONObject: [
            "aRevisions": reservedA, "bCommittedFloor": floorBeforeA, "intermediateA": 1, "intermediateB": 5,
            "reopenedCoverage": [savedA.messageCoveredThroughSeq ?? -1, savedB.messageCoveredThroughSeq ?? -1]
        ])
        let trace = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
        trace.name = "m12-sqlite-projection-race-reopened"
        trace.lifetime = .keepAlways
        add(trace)
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END

    private func seedSequenceRecovery(_ f: BackgroundDecodeFixture) async throws -> ConversationMessageSnapshot {
        var row = computeRow("decode-channel", messageID: "base")
        row.lastMsgSeq = 5
        row.messageCoverageRequiresRecovery = true
        let ticket = try XCTUnwrap(f.state.localMessageTicket)
        _ = try await f.persistence.persist(ticket: ticket, snapshots: [
            LocalMessageConversationSnapshot(conversation: row, channelID: row.id, channelType: "group",
                currentActorID: "actor-a")
        ], source: .history, revision: f.state.nextLocalMessageProjectionRevision())
        let disk = try await f.persistence.activateAndLoad(context: f.state.apiContext,
            sessionGeneration: f.state.localMessageSessionGeneration)
        XCTAssertEqual(disk.conversations.first?.messageCoveredThroughSeq, 1)
        XCTAssertEqual(disk.conversations.first?.lastMsgSeq, 5)
        f.state.conversationStore.hydrateCachedConversations([row])
        let baseline = f.state.remoteSyncEngine.remoteConversationSyncCommand(forceFull: false)
        f.state.remoteSyncEngine.finishRemoteConversationSync(baseline, responseVersion: 1)
        return row
    }

    private func recoveryPage(_ sequences: [Int64], nextAfter: Int64, hasMore: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
            "items": sequences.map { computeMessage("recovery-\($0)", sequence: $0) },
            "next_after_seq": nextAfter, "has_more_after": hasMore
        ]])
    }

    private func recoverySession(pages: [Data]) -> URLSession {
        Phase6HistoryURLProtocol.installRecovery(pages)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase6HistoryURLProtocol.self]
        return URLSession(configuration: config)
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
    // WDT_IOS1_MOUNTED_RECOVERY_DEFAULTS_SUITE_20261112_BEGIN
    private func trackedRecoveryFixture(
        pages: [Data], defaultsSuite: String? = nil
    ) async throws -> (BackgroundDecodeFixture, Phase6RecoveryFixtureLifetime) {
    // WDT_IOS1_MOUNTED_RECOVERY_DEFAULTS_SUITE_20261112_END
        // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_BEGIN
        let suite = defaultsSuite ?? ("phase6-recovery-" + UUID().uuidString) // WDT_IOS1_MOUNTED_RECOVERY_DEFAULTS_SUITE_20261112
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let http = Phase6RecoveryHTTPTransport(session: recoverySession(pages: pages))
        do {
            let fixture = try await phase6HTTPFixture(responses: [], transport: http, isolatedDefaults: defaults)
            let recovery = Phase6RecoveryFixtureLifetime(fixture: fixture, http: http) {
                Phase6HistoryURLProtocol.install(nil)
                defaults.removePersistentDomain(forName: suite)
            }
            addTeardownBlock { await recovery.drain() }
            return (fixture, recovery)
        } catch {
            await http.drain()
            Phase6HistoryURLProtocol.install(nil)
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
        // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_END
    }

    private func checkRetirementWhileMappingRecoveryPage(_ page: Data) async throws {
        let (fixture, recovery) = try await trackedRecoveryFixture(pages: [page])
        defer { recovery.retire() }
        let row = try await seedSequenceRecovery(fixture)
        let entered = expectation(description: "recovery page decoded before early fixture exit")
        recovery.suspendFirstMapping(entered)
        let state = fixture.state
        let ticket = try XCTUnwrap(state.localMessageTicket)
        let initialFloor = try await fixture.persistence.projectionRevisionFloor(ticket: ticket)
        let target = try XCTUnwrap(state.conversationStore.messageSequenceRecoveryTarget(for: row))
        state.scheduleMessageSequenceRecovery(conversationID: row.id, target: target, reason: "fixture_retirement")
        await fulfillment(of: [entered], timeout: 4)
        XCTAssertEqual(Phase6HistoryURLProtocol.recoveryRequests.map(\.after), [1])
        let historyKey = state.conversationHistoryStateKey(for: row)
        XCTAssertTrue(recovery.hasTrackedRecovery)
        XCTAssertTrue(state.conversationStore.isMessageSyncInFlight(historyKey: historyKey))
        // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_BEGIN
        try await recovery.verifyHeldPageRetirement(conversationID: row.id, historyKey: historyKey,
            ticket: ticket, initialFloor: initialFloor)
        // WDT_IOS1_RECOVERY_FIXTURE_HTTP_LIFETIME_20261112_END
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END
    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END

    private func phase6Page(_ messages: [[String: Any]]) throws -> HTTPTransportResult {
        HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["items": messages,
            "history_visible_from_seq": 1, "history_limited": false, "has_more_before": false]]), isHTTPResponse: true, statusCode: 200)
    }

    // WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111_BEGIN
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
    // WDT_IOS1_PHASE6_NATIVE_MOUNTED_CHAIN_20261111_END

    // These two original builders are also private to the realtime/HTTP tests in the original file.
    private func computeRow(_ id: String, messageID: String, kind: ConversationKind = .group) -> ConversationMessageSnapshot {
        var row = makeConversation(id: id, kind: kind, unread: 0, lastMsgSeq: 1, lastReadSeq: 1)
        row.messages = [makeMessage(id: messageID, seq: 1)]; row.messageCoveredThroughSeq = 1
        return row
    }
    private func computeMessage(_ id: String, sequence: Int64, channel: String = "decode-channel", sender: String = "peer") -> [String: Any] {
        ["message_id": id, "channel_id": channel, "channel_type": "group", "channel_seq": sequence, "from_uid": sender,
         "content_type": "text", "created_at": "2026-11-10T01:00:00Z", "payload": ["text": id]]
    }
}

// WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_BEGIN
private final class Phase6NativeTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let observed: XCTestExpectation
    private var emissions: [MessageDerivationInstrumentation.Emission] = []
    private var reported = false
    init(observed: XCTestExpectation) { self.observed = observed }
    func record(_ event: MessageDerivationInstrumentation.Emission) {
        let shouldReport = lock.withLock {
            emissions.append(event)
            guard !reported, case .sample(let value) = event, value.phase == .projectionObserved,
                  !value.context.sourceCorrelations.isEmpty else { return false }
            reported = true
            return true
        }
        if shouldReport { observed.fulfill() }
    }
    func snapshot() -> [MessageDerivationInstrumentation.Emission] { lock.withLock { emissions } }
}

private final class Phase6HistoryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: Data?
    nonisolated(unsafe) private static var hits = 0
    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
    struct RecoveryRequest: Sendable {
        let after: Int64?
        let limit: Int?
    }
    nonisolated(unsafe) private static var recoveryPages: [Data]?
    nonisolated(unsafe) private static var recoveryHits: [RecoveryRequest] = []
    static var recoveryRequests: [RecoveryRequest] { lock.withLock { recoveryHits } }
    static func installRecovery(_ pages: [Data]) {
        lock.withLock {
            fixture = nil
            hits = 0
            recoveryPages = pages
            recoveryHits = []
        }
    }
    private static func recoveryRequest(_ request: URLRequest) -> RecoveryRequest {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while true {
                let count = stream.read(&buffer, maxLength: bufferSize)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return RecoveryRequest(after: (payload?["after_seq"] as? NSNumber)?.int64Value,
            limit: (payload?["limit"] as? NSNumber)?.intValue)
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
    static var requestCount: Int { lock.withLock { hits } }
    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
    static func install(_ data: Data?) {
        lock.withLock {
            fixture = data
            hits = 0
            recoveryPages = nil
            recoveryHits = []
        }
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let data: Data? = Self.lock.withLock {
            // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
            if url.path == "/api/platform/apps/current-policy",
               let appID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "app_id" })?.value {
                return try? JSONSerialization.data(withJSONObject: ["ok": true, "data": [
                    "app_id": appID, "platform": "ios", "status": "active",
                    "require_real_name": false, "require_phone_verification": false, "cache_ttl_seconds": 60
                ]])
            }
            if Self.recoveryPages != nil, request.httpMethod == "POST", url.path == "/api/im/conversations/sync" {
                return Data(#"{"ok":true,"data":{"version":2,"conversations":[]}}"#.utf8)
            }
            // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
            guard request.httpMethod == "POST", url.path == "/api/im/sync" else { return nil }
            Self.hits += 1
            // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
            if let pages = Self.recoveryPages {
                let index = Self.recoveryHits.count
                Self.recoveryHits.append(Self.recoveryRequest(request))
                return index < pages.count ? pages[index] : nil
            }
            // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
            return Self.fixture
        }
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data(#"{"ok":false,"error":{"code":"not_found"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
// WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_END
// WDT_IOS1_SPLIT_REALTIME_DOMAIN_TEST_SOURCES_20261111_END

// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_BEGIN
extension DomainStoreTests {
    func testPhase6HTTPDirectAliasTraceBindsToActualStoreWindow() async throws {
        var row = computeRow("local-direct-row", messageID: "base", kind: .direct)
        row.participants = [makeUser(id: "peer")]
        let f = try await phase6HTTPFixture(responses: [])
        defer { f.close() }
        f.state.conversationStore.commitConversationSnapshots([row])
        let channel = f.state.remoteChannelID(for: row)
        var remote = computeMessage("direct-arrived", sequence: 2, channel: channel)
        remote["channel_type"] = "direct"
        // Use the same real HTTP fixture with the actual remote channel and independent local row ID.
        let g = try await phase6HTTPFixture(responses: [phase6Page([remote])])
        defer { g.close() }
        g.state.conversationStore.commitConversationSnapshots([row])
        var samples: [MessageDerivationSample] = []
        g.state.realtimeComputeRuntime.onDerivation = { samples += $0 }
        let target = await g.state.prepareMessageJump(messageID: "direct-arrived", channelSeq: 2, conversationID: row.id)
        XCTAssertEqual(target, "direct-arrived")
        XCTAssertNotEqual(channel, row.id)
        let installed = samples.filter { $0.phase == .storeInstalled }
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.outputRevision, g.state.conversationStore.memorySnapshot.revision)
        // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
        XCTAssertEqual(installed.first?.context.sourceCorrelations.count, 1)
        XCTAssertEqual(installed.first?.context, samples.first { $0.phase == .mapping }?.context)
        // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END
        XCTAssertEqual(g.state.conversationStore.conversationMessageSnapshot(id: row.id)?.messages.map(\.id), ["base", "direct-arrived"])
    }

    // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
    func testPhase6HTTPTraceScopeRestoresNestedContextAndOriginalErrors() async throws {
        enum OriginalFailure: Error { case expected }
        let f = try await phase6HTTPFixture(responses: [])
        defer { f.close() }
        XCTAssertNil(SDKHTTPTrace.current)
        let outer: SDKHTTPTraceContext = (81, { _, _, _ in }, { _, _, _ in }, { _ in })
        try await SDKHTTPTrace.$current.withValue(outer) {
            let result = try await f.state.traceMessageHTTPRequest {
                let first = try XCTUnwrap(SDKHTTPTrace.current)
                XCTAssertNotEqual(first.sourceCorrelation, outer.sourceCorrelation)
                let nested = try await f.state.traceMessageHTTPRequest {
                    let second = try XCTUnwrap(SDKHTTPTrace.current)
                    XCTAssertNotEqual(first.sourceCorrelation, second.sourceCorrelation)
                    return second.sourceCorrelation
                }
                XCTAssertEqual(nested.value, nested.sourceCorrelation)
                XCTAssertEqual(SDKHTTPTrace.current?.sourceCorrelation, first.sourceCorrelation)
                return first.sourceCorrelation
            }
            XCTAssertEqual(result.value, result.sourceCorrelation)
            XCTAssertEqual(SDKHTTPTrace.current?.sourceCorrelation, outer.sourceCorrelation)
            do {
                let _: (value: Int, sourceCorrelation: UInt64) = try await f.state.traceMessageHTTPRequest {
                    throw OriginalFailure.expected
                }
                XCTFail("original error must escape")
            } catch OriginalFailure.expected { }
            XCTAssertEqual(SDKHTTPTrace.current?.sourceCorrelation, outer.sourceCorrelation)
            do {
                let _: (value: Int, sourceCorrelation: UInt64) = try await f.state.traceMessageHTTPRequest {
                    throw CancellationError()
                }
                XCTFail("original cancellation must escape")
            } catch is CancellationError { }
            XCTAssertEqual(SDKHTTPTrace.current?.sourceCorrelation, outer.sourceCorrelation)
        }
        XCTAssertNil(SDKHTTPTrace.current)
        XCTAssertTrue(f.http.requests().isEmpty)
    }

    func testPhase6CapturedEmitterPreservesExecutionValuesAndLinks() throws {
        XCTAssertTrue(Thread.isMainThread)
        let captured = MessageDerivationSample(
            context: MessageDerivationTraceContext(operation: 101, sourceCorrelations: [202, 303]),
            phase: .decode, inputRevision: 17, outputRevision: 19, attempt: 3,
            durationNanoseconds: 43, onMainThread: false, uptimeNanoseconds: 47)
        let emitted = MessageDerivationInstrumentation.emit(captured)
        XCTAssertEqual(emitted, captured)
        XCTAssertFalse(emitted.onMainThread, "callback thread must not replace execution thread")
        XCTAssertEqual(MessageDerivationInstrumentation.emit([captured, captured]), [captured, captured])
        XCTAssertEqual(try JSONDecoder().decode(MessageDerivationSample.self,
            from: JSONEncoder().encode(emitted)), captured)
    }
    // WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END
}
// WDT_IOS1_PHASE6_TEST_FILE_SIZE_SPLIT_20261112_END

// WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_BEGIN
final class Phase6QueuedHistoryTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let pages: [String: HTTPTransportResult]
    private var channels: [String] = []

    init(pages: [String: HTTPTransportResult]) { self.pages = pages }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        if request.url?.path == "/api/platform/apps/current-policy" {
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": [
                "app_id": IMAPIContext.canonicalIOSAppID, "platform": "ios", "status": "active",
                "require_real_name": false, "require_phone_verification": false, "cache_ttl_seconds": 60
            ]])
            return HTTPTransportResult(data: data, isHTTPResponse: true, statusCode: 200)
                .resolvingResponseURL(request.url)
        }
        guard request.httpMethod == "POST", request.url?.path == "/api/im/sync",
              let body = request.httpBody,
              let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let channel = payload["channel_id"] as? String,
              let page = pages[channel] else { throw URLError(.unsupportedURL) }
        lock.withLock { channels.append(channel) }
        return page.resolvingResponseURL(request.url)
    }

    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw URLError(.unsupportedURL)
    }

    func requestedChannels() -> [String] { lock.withLock { channels } }
}
// WDT_IOS1_HTTP_DERIVATION_FIXTURE_ADMISSION_20261112_END

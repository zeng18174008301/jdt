import XCTest
@testable import BlueStoneIM

final class SyncEngineTests: XCTestCase {
    func testConversationPresentationPreservesMutationsAndDeletesOnlyOnCompletion() {
        var rows = ["old": 1, "pin": 1, "read": 1, "removed": 1]
        var projection = ConversationSnapshotPresentation(current: rows)
        XCTAssertTrue(projection.accept("first", current: rows))
        rows["first"] = 2
        projection.didApply(["first"], current: rows)
        XCTAssertFalse(projection.accept("first", current: rows), "Duplicate pages cannot replay older settings")
        XCTAssertEqual(rows["old"], 1)
        rows["pin"] = 2
        rows["read"] = 2
        rows["removed"] = nil
        rows["realtime"] = 3
        for key in ["pin", "read", "removed", "realtime"] {
            XCTAssertFalse(projection.accept(key, current: rows))
        }
        let completed = projection.completing(current: rows)
        XCTAssertNil(completed["old"])
        XCTAssertNil(completed["removed"])
        XCTAssertEqual(completed, ["first": 2, "pin": 2, "read": 2, "realtime": 3])
    }

    func testConversationPresentationRestartDiscardsOnlyUnchangedOldAttempt() {
        var rows = ["baseline": 1, "changed": 1]
        var projection = ConversationSnapshotPresentation(current: rows)
        for key in ["baseline", "changed", "speculative"] {
            XCTAssertTrue(projection.accept(key, current: rows))
            rows[key] = 2
        }
        projection.didApply(["baseline", "changed", "speculative"], current: rows)
        rows["changed"] = 3
        rows = projection.restarting(current: rows)
        XCTAssertEqual(rows, ["baseline": 1, "changed": 3])
        XCTAssertFalse(projection.accept("changed", current: rows))
        XCTAssertTrue(projection.accept("new", current: rows))
        rows["new"] = 4
        projection.didApply(["new"], current: rows)
        XCTAssertEqual(projection.completing(current: rows), ["changed": 3, "new": 4])
    }

    func testConversationPresentationPreservesMutationEvenWhenValueReturnsToBaseline() {
        var rows = ["pin": 0, "deleted": 0]
        var projection = ConversationSnapshotPresentation(current: rows)
        rows["pin"] = 1
        rows["deleted"] = nil
        projection.observe(current: rows)
        rows = ["pin": 0, "deleted": 0]
        projection.observe(current: rows)
        XCTAssertFalse(projection.accept("pin", current: rows))
        XCTAssertFalse(projection.accept("deleted", current: rows))
        XCTAssertEqual(projection.completing(current: rows), rows)
    }

    func testDefaultSyncEngineDedupesByHistoryKey() {
        let engine = DefaultSyncEngine()
        let request = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: "conversation-1",
            historyKey: "conversation-1:after:10",
            reason: "initial"
        )

        let firstResult = engine.begin(request)
        let secondResult = engine.begin(request)

        XCTAssertTrue(firstResult.started)
        XCTAssertNil(firstResult.skippedReason)
        XCTAssertFalse(secondResult.started)
        XCTAssertEqual(secondResult.skippedReason, "sync request already in flight")
        XCTAssertTrue(engine.isInFlight(request))
    }

    func testDefaultSyncEngineAllowsDistinctHistoryKeysForSameConversation() {
        let engine = DefaultSyncEngine()
        let firstRequest = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: "conversation-1",
            historyKey: "conversation-1:after:10",
            reason: "initial"
        )
        let secondRequest = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: "conversation-1",
            historyKey: "conversation-1:after:20",
            reason: "warm-refresh"
        )

        XCTAssertTrue(engine.begin(firstRequest).started)
        XCTAssertTrue(engine.begin(secondRequest).started)
        XCTAssertTrue(engine.isInFlight(firstRequest))
        XCTAssertTrue(engine.isInFlight(secondRequest))
    }

    func testDefaultSyncEngineFinishReleasesRequest() {
        let engine = DefaultSyncEngine()
        let request = SyncEngineRequest(
            operation: .olderMessages,
            conversationID: "conversation-1",
            historyKey: "conversation-1:before:50",
            reason: "load-older"
        )

        XCTAssertTrue(engine.begin(request).started)
        engine.finish(request)

        XCTAssertFalse(engine.isInFlight(request))
        XCTAssertTrue(engine.begin(request).started)
    }

    func testDefaultSyncEngineResetClearsInFlightRequests() {
        let engine = DefaultSyncEngine()
        let request = SyncEngineRequest(
            operation: .remoteSnapshot,
            reason: "login-bootstrap"
        )

        XCTAssertTrue(engine.begin(request).started)
        engine.reset()

        XCTAssertFalse(engine.isInFlight(request))
        XCTAssertTrue(engine.begin(request).started)
    }

    func testDefaultSyncEngineDedupesRemoteSnapshotByScope() {
        let engine = DefaultSyncEngine()
        let firstScope = SyncEngineRequest(
            operation: .remoteSnapshot,
            historyKey: "tenant-a|user-1|device-1",
            reason: "foreground"
        )
        let duplicateScope = SyncEngineRequest(
            operation: .remoteSnapshot,
            historyKey: "tenant-a|user-1|device-1",
            reason: "reconnect"
        )
        let secondScope = SyncEngineRequest(
            operation: .remoteSnapshot,
            historyKey: "tenant-b|user-1|device-1",
            reason: "workspace-switch"
        )

        XCTAssertTrue(engine.begin(firstScope).started)
        XCTAssertFalse(engine.begin(duplicateScope).started)
        XCTAssertTrue(engine.begin(secondScope).started)
    }

    func testDefaultSyncEngineRemoteSnapshotPlanBuildsCommandWithScopeAndForceReason() {
        let engine = DefaultSyncEngine()

        let normalPlan = engine.remoteSnapshotSyncPlan(scope: " tenant-a|user-1|device-1 ", force: false)
        let forcePlan = engine.remoteSnapshotSyncPlan(scope: "tenant-a|user-1|device-1", force: true)

        XCTAssertEqual(
            normalPlan,
            .remoteSnapshot(RemoteSnapshotSyncCommand(scope: "tenant-a|user-1|device-1", force: false))
        )
        XCTAssertEqual(
            forcePlan,
            .remoteSnapshot(RemoteSnapshotSyncCommand(scope: "tenant-a|user-1|device-1", force: true))
        )

        guard case .remoteSnapshot(let command) = forcePlan else {
            XCTFail("Expected remote snapshot command")
            return
        }
        XCTAssertEqual(command.request.operation, .remoteSnapshot)
        XCTAssertEqual(command.request.historyKey, "tenant-a|user-1|device-1")
        XCTAssertEqual(command.request.reason, "force")
    }

    func testDefaultSyncEngineRemoteSnapshotPlanSkipsEmptyScopeAndInFlightScope() {
        let engine = DefaultSyncEngine()
        let command = RemoteSnapshotSyncCommand(scope: "tenant-a|user-1|device-1", force: true)

        XCTAssertEqual(
            engine.remoteSnapshotSyncPlan(scope: "   ", force: true),
            .skip(RemoteSnapshotSyncCommand(scope: "", force: true), reason: "empty remote snapshot scope")
        )
        XCTAssertTrue(engine.beginRemoteSnapshotSync(command).started)
        XCTAssertEqual(
            engine.remoteSnapshotSyncPlan(scope: "tenant-a|user-1|device-1", force: true),
            .skip(command, reason: "remote snapshot already in flight")
        )

        engine.finishRemoteSnapshotSync(command)

        XCTAssertEqual(
            engine.remoteSnapshotSyncPlan(scope: "tenant-a|user-1|device-1", force: true),
            .remoteSnapshot(command)
        )
    }

    func testAppStateCoalescesOneForcedSnapshotSuccessorAfterInFlightOwner() throws {
        let appStateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../BlueStoneIM/AppState.swift")
            .standardizedFileURL
        let source = try String(contentsOf: appStateURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private func refreshRemoteSnapshot")?.lowerBound
        )
        let tail = source[start...]
        let end = try XCTUnwrap(
            tail.range(of: "private func syncPrimaryConversationData")?.lowerBound
        )
        let section = tail[..<end]

        XCTAssertTrue(section.contains("pendingForcedRemoteSnapshotSuccessorScopes.insert(scope)"))
        XCTAssertTrue(section.contains("scheduleForcedRemoteSnapshotSuccessorIfNeeded(scope: scope)"))
        XCTAssertTrue(section.contains("pendingForcedRemoteSnapshotSuccessorScopes.remove(scope)"))
        XCTAssertTrue(section.contains("await Task.yield()"))
        XCTAssertTrue(section.contains("self.isCurrentRemoteScope(scope)"))
    }

    func testDefaultSyncEngineRemoteSnapshotRefreshSessionReplacesFinishesAndResetInvalidates() {
        let engine = DefaultSyncEngine()
        let firstSession = engine.beginRemoteSnapshotRefresh()

        XCTAssertEqual(engine.currentRemoteSnapshotGeneration(), firstSession.generation)
        XCTAssertEqual(engine.currentRemoteSnapshotRefreshSession(), firstSession)
        XCTAssertTrue(engine.isCurrentRemoteSnapshotRefresh(firstSession))
        XCTAssertTrue(engine.isCurrentRemoteSnapshotGeneration(firstSession.generation))

        let secondSession = engine.beginRemoteSnapshotRefresh()

        XCTAssertFalse(engine.isCurrentRemoteSnapshotRefresh(firstSession))
        XCTAssertTrue(engine.isCurrentRemoteSnapshotRefresh(secondSession))
        XCTAssertEqual(engine.currentRemoteSnapshotRefreshSession(), secondSession)
        XCTAssertFalse(engine.finishRemoteSnapshotRefresh(firstSession))
        XCTAssertTrue(engine.isCurrentRemoteSnapshotRefresh(secondSession))
        XCTAssertTrue(engine.finishRemoteSnapshotRefresh(secondSession))
        XCTAssertFalse(engine.finishRemoteSnapshotRefresh(secondSession))
        XCTAssertTrue(engine.isCurrentRemoteSnapshotRefresh(secondSession))
        XCTAssertEqual(engine.currentRemoteSnapshotRefreshSession(), secondSession)
        XCTAssertTrue(engine.isCurrentRemoteSnapshotGeneration(secondSession.generation))

        let thirdSession = engine.beginRemoteSnapshotRefresh()
        XCTAssertFalse(engine.isCurrentRemoteSnapshotRefresh(secondSession))
        XCTAssertEqual(engine.currentRemoteSnapshotRefreshSession(), thirdSession)
        engine.reset()

        XCTAssertFalse(engine.isCurrentRemoteSnapshotRefresh(thirdSession))
        XCTAssertNil(engine.currentRemoteSnapshotRefreshSession())
        XCTAssertFalse(engine.isCurrentRemoteSnapshotGeneration(thirdSession.generation))
        XCTAssertEqual(engine.currentRemoteSnapshotGeneration(), thirdSession.generation + 1)

        let fourthSession = engine.beginRemoteSnapshotRefresh()
        XCTAssertEqual(fourthSession.generation, thirdSession.generation + 1)
        XCTAssertEqual(engine.currentRemoteSnapshotRefreshSession(), fourthSession)
        XCTAssertTrue(engine.finishRemoteSnapshotRefresh(fourthSession))
    }

    func testDefaultSyncEngineRemoteConversationSyncVersionIsMonotonicForceFullAndResettable() {
        let engine = DefaultSyncEngine()

        XCTAssertEqual(engine.requestedRemoteConversationSyncVersion(forceFull: false), 0)
        XCTAssertEqual(engine.requestedRemoteConversationSyncVersion(forceFull: true), 0)

        engine.rememberRemoteConversationSyncVersion(42)

        XCTAssertEqual(engine.currentRemoteConversationSyncVersion(), 42)
        XCTAssertEqual(engine.requestedRemoteConversationSyncVersion(forceFull: false), 42)
        XCTAssertEqual(engine.requestedRemoteConversationSyncVersion(forceFull: true), 0)

        engine.rememberRemoteConversationSyncVersion(7)

        XCTAssertEqual(engine.currentRemoteConversationSyncVersion(), 42)

        engine.rememberRemoteConversationSyncVersion(100)

        XCTAssertEqual(engine.requestedRemoteConversationSyncVersion(forceFull: false), 100)

        engine.reset()

        XCTAssertEqual(engine.currentRemoteConversationSyncVersion(), 0)
        XCTAssertEqual(engine.requestedRemoteConversationSyncVersion(forceFull: false), 0)
    }

    func testDefaultSyncEngineRemoteConversationSyncCommandTracksVersionAndReplacementMode() {
        let engine = DefaultSyncEngine()

        let initial = engine.remoteConversationSyncCommand(forceFull: false)

        XCTAssertEqual(initial.requestedVersion, 0)
        XCTAssertFalse(initial.forceFull)
        XCTAssertTrue(initial.replacesLocalSnapshot)

        engine.finishRemoteConversationSync(initial, responseVersion: 42)

        let incremental = engine.remoteConversationSyncCommand(forceFull: false)
        XCTAssertEqual(incremental.requestedVersion, 42)
        XCTAssertFalse(incremental.replacesLocalSnapshot)

        let forceFull = engine.remoteConversationSyncCommand(forceFull: true)
        XCTAssertEqual(forceFull.requestedVersion, 0)
        XCTAssertTrue(forceFull.forceFull)
        XCTAssertTrue(forceFull.replacesLocalSnapshot)

        engine.finishRemoteConversationSync(forceFull, responseVersion: 7)

        XCTAssertEqual(engine.currentRemoteConversationSyncVersion(), 42)

        engine.finishRemoteConversationSync(incremental, responseVersion: 100)

        XCTAssertEqual(engine.currentRemoteConversationSyncVersion(), 100)
        XCTAssertEqual(engine.remoteConversationSyncCommand(forceFull: false).requestedVersion, 100)
    }

    func testDefaultSyncEngineBuildsSecondarySnapshotCommandsInStableOrder() {
        let engine = DefaultSyncEngine()

        let commands = engine.secondarySnapshotCommands(
            groupsDelayNs: 700,
            contactsDelayNs: 1_300,
            profileDeviceDelayNs: 2_200
        )

        XCTAssertEqual(
            commands,
            [
                SecondarySnapshotSyncCommand(operation: .groups, delayNs: 700),
                SecondarySnapshotSyncCommand(operation: .contacts, delayNs: 1_300),
                SecondarySnapshotSyncCommand(operation: .profileDevice, delayNs: 2_200)
            ]
        )
        XCTAssertEqual(commands.map(\.name), ["groups", "contacts", "profile_device"])
    }

    func testDefaultSyncEngineSecondarySnapshotTaskLifecycleClaimsFinishesCancelsAndResetClearsState() {
        let engine = DefaultSyncEngine()
        let groupsTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let contactsTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        XCTAssertTrue(engine.claimSecondarySnapshotTask(.groups))
        XCTAssertTrue(engine.hasSecondarySnapshotTask(.groups))
        XCTAssertFalse(engine.claimSecondarySnapshotTask(.groups))
        XCTAssertTrue(engine.claimSecondarySnapshotTask(.contacts))

        engine.attachSecondarySnapshotTask(.groups, task: groupsTask)
        engine.attachSecondarySnapshotTask(.contacts, task: contactsTask)
        engine.finishSecondarySnapshotTask(.groups)
        groupsTask.cancel()

        XCTAssertFalse(engine.hasSecondarySnapshotTask(.groups))
        XCTAssertTrue(engine.hasSecondarySnapshotTask(.contacts))

        engine.cancelSecondarySnapshotTasks()

        XCTAssertFalse(engine.hasSecondarySnapshotTask(.contacts))
        XCTAssertTrue(engine.claimSecondarySnapshotTask(.profileDevice))

        let resetTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        engine.attachSecondarySnapshotTask(.profileDevice, task: resetTask)
        engine.reset()

        XCTAssertFalse(engine.hasSecondarySnapshotTask(.profileDevice))
        XCTAssertTrue(engine.claimSecondarySnapshotTask(.groups))

        engine.cancelSecondarySnapshotTasks()
    }

    func testDefaultSyncEngineInboxRefreshTaskLifecycleUsesTokenAndResetClearsState() {
        let engine = DefaultSyncEngine()
        guard let firstToken = engine.claimInboxRefreshTask() else {
            XCTFail("Expected first inbox refresh task claim to succeed")
            return
        }
        let firstTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        XCTAssertTrue(engine.hasInboxRefreshTask())
        XCTAssertNil(engine.claimInboxRefreshTask())

        engine.attachInboxRefreshTask(firstToken, task: firstTask)
        engine.cancelInboxRefreshTask()

        XCTAssertFalse(engine.hasInboxRefreshTask())

        guard let secondToken = engine.claimInboxRefreshTask() else {
            XCTFail("Expected inbox refresh task claim after cancel to succeed")
            return
        }
        let secondTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        engine.attachInboxRefreshTask(secondToken, task: secondTask)
        engine.finishInboxRefreshTask(firstToken)

        XCTAssertTrue(engine.hasInboxRefreshTask())

        engine.finishInboxRefreshTask(secondToken)
        secondTask.cancel()

        XCTAssertFalse(engine.hasInboxRefreshTask())

        guard let resetToken = engine.claimInboxRefreshTask() else {
            XCTFail("Expected inbox refresh task claim before reset to succeed")
            return
        }
        let resetTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        engine.attachInboxRefreshTask(resetToken, task: resetTask)
        engine.reset()

        XCTAssertFalse(engine.hasInboxRefreshTask())
        XCTAssertNotNil(engine.claimInboxRefreshTask())

        engine.cancelInboxRefreshTask()
    }

    func testDefaultSyncEngineAuthSessionRefreshTaskLifecycleDedupesFinishesCancelsAndResetClearsState() {
        let engine = DefaultSyncEngine()
        guard let firstToken = engine.claimAuthSessionRefreshTask() else {
            XCTFail("Expected first auth session refresh task claim to succeed")
            return
        }
        let firstTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return true
        }

        XCTAssertTrue(engine.hasAuthSessionRefreshTask())
        XCTAssertNil(engine.claimAuthSessionRefreshTask())

        engine.attachAuthSessionRefreshTask(firstToken, task: firstTask)

        XCTAssertNotNil(engine.currentAuthSessionRefreshTask())

        engine.cancelAuthSessionRefreshTask()

        XCTAssertFalse(engine.hasAuthSessionRefreshTask())
        XCTAssertNil(engine.currentAuthSessionRefreshTask())

        guard let secondToken = engine.claimAuthSessionRefreshTask() else {
            XCTFail("Expected auth session refresh task claim after cancel to succeed")
            return
        }
        let secondTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return true
        }
        engine.attachAuthSessionRefreshTask(secondToken, task: secondTask)
        engine.finishAuthSessionRefreshTask(firstToken)

        XCTAssertTrue(engine.hasAuthSessionRefreshTask())
        XCTAssertNotNil(engine.currentAuthSessionRefreshTask())

        engine.finishAuthSessionRefreshTask(secondToken)
        secondTask.cancel()

        XCTAssertFalse(engine.hasAuthSessionRefreshTask())
        XCTAssertNil(engine.currentAuthSessionRefreshTask())

        guard let resetToken = engine.claimAuthSessionRefreshTask() else {
            XCTFail("Expected auth session refresh task claim before reset to succeed")
            return
        }
        let resetTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return true
        }
        engine.attachAuthSessionRefreshTask(resetToken, task: resetTask)
        engine.reset()

        XCTAssertFalse(engine.hasAuthSessionRefreshTask())
        XCTAssertNil(engine.currentAuthSessionRefreshTask())
        XCTAssertNotNil(engine.claimAuthSessionRefreshTask())

        engine.cancelAuthSessionRefreshTask()
    }

    func testAuthSessionRefreshFenceAllowsExactlyOneClaimAcrossOneHundredConcurrent401s() async {
        let engine = DefaultSyncEngine()
        let fence = IMAuthSessionFence(
            epoch: "epoch-a",
            credentialRevision: 4,
            principalKey: "account-a|tenant-a|uid-a|app-a|device-a",
            platformSessionID: "platform-a",
            tenantSessionID: "tenant-session-a",
            authorityFamily: .tenant,
            authVersion: 9,
            sessionGeneration: 12
        )

        let winners = await withTaskGroup(of: AuthSessionRefreshTaskToken?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    engine.claimAuthSessionRefreshTask(for: fence)
                }
            }
            var claimed: [AuthSessionRefreshTaskToken] = []
            for await token in group {
                if let token { claimed.append(token) }
            }
            return claimed
        }

        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(winners.first?.fence, fence)
        if let winner = winners.first {
            engine.finishAuthSessionRefreshTask(winner)
        }
        XCTAssertFalse(engine.hasAuthSessionRefreshTask())
    }

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

    func testSyncEngineRequestFallsBackToGlobalKey() {
        let request = SyncEngineRequest(operation: .realtimeRecovery, reason: "socket-reconnect")

        XCTAssertEqual(request.inFlightKey, "realtimeRecovery:global")
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

    func testDefaultSyncEngineRemoteErrorToastPlanNormalizesThrottlesByMessageAndResetClearsState() {
        let engine = DefaultSyncEngine()
        let now = Date(timeIntervalSince1970: 4_000)

        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "   ", now: now, throttleInterval: 12),
            .skip(message: "", reason: "empty remote error toast")
        )
        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "  网络错误  ", now: now, throttleInterval: 12),
            .show(message: "网络错误")
        )

        engine.rememberRemoteErrorToastShown(message: "网络错误", at: now)

        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: " 网络错误 ", now: now.addingTimeInterval(11.9), throttleInterval: 12),
            .skip(message: "网络错误", reason: "remote error toast throttled")
        )
        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "其它错误", now: now.addingTimeInterval(1), throttleInterval: 12),
            .show(message: "其它错误")
        )
        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "网络错误", now: now.addingTimeInterval(12), throttleInterval: 12),
            .show(message: "网络错误")
        )

        engine.clearRemoteErrorToastThrottle()

        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "网络错误", now: now.addingTimeInterval(1), throttleInterval: 12),
            .show(message: "网络错误")
        )

        engine.rememberRemoteErrorToastShown(message: "网络错误", at: now.addingTimeInterval(1))
        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "网络错误", now: now.addingTimeInterval(2), throttleInterval: 12),
            .skip(message: "网络错误", reason: "remote error toast throttled")
        )

        engine.reset()

        XCTAssertEqual(
            engine.remoteErrorToastPlan(message: "网络错误", now: now.addingTimeInterval(2), throttleInterval: 12),
            .show(message: "网络错误")
        )
    }

    func testSyncEngineRequestKeepsEmptyHistoryKeyDistinctFromGlobalKey() {
        let historyRequest = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: "conversation-1",
            historyKey: "",
            reason: "legacy-empty-history-key"
        )
        let globalRequest = SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: nil,
            historyKey: nil,
            reason: "global"
        )

        XCTAssertEqual(historyRequest.inFlightKey, "conversationMessages:history:")
        XCTAssertEqual(globalRequest.inFlightKey, "conversationMessages:global")
    }
}

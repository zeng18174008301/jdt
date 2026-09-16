import XCTest
@testable import BlueStoneIM

final class CallLifecycleTests: XCTestCase {
    func testIncomingMediaModeDeterminesVoiceOrVideoRegardlessOfSourceCopy() {
        let caller = IMUser(
            id: "caller", name: "Caller", title: "", department: "", phone: "",
            email: "", status: "active", enterprise: "", avatarSeed: 1, badges: []
        )
        let cases: [(mode: String, source: String, isVideo: Bool)] = [
            ("audio", "好友视频通话", false),
            ("  AuDiO\n", "视频来电", false),
            ("video", "好友语音通话", true),
            ("\n ViDeO  ", "语音来电", true),
            ("", "视频来电", false),
            ("unknown", "视频来电", false)
        ]
        for item in cases {
            let call = IncomingVoiceCall(
                id: "incoming", callID: "call-1", caller: caller, startedAt: "刚刚",
                source: item.source, requestedMediaMode: item.mode
            )
            XCTAssertEqual(call.isVideo, item.isVideo, "media mode: \(item.mode.debugDescription)")
        }
    }

    func testIncomingTerminalPhasesStopRingtoneAndReleaseRingingOwnership() {
        let terminalPhases: [CallLifecyclePhase] = [
            .busy, .rejected, .cancelled, .timeout, .ended, .failure
        ]
        for phase in terminalPhases {
            var lifecycle = CallLifecycleStateMachine()
            var prompts = CallPromptCoordinator()
            let identity = CallLifecycleSessionIdentity(callID: "incoming-\(phase.rawValue)", epoch: 1)
            let claim = lifecycle.claim(identity, direction: .incoming)
            XCTAssertEqual(claim.current?.phase, .ringing)
            XCTAssertTrue(prompts.commands(for: claim).contains(.startLoop(.incomingRingtone)))

            let terminal = lifecycle.apply(.init(identity: identity, phase: phase, revision: 1))
            XCTAssertTrue(terminal.isApplied, "\(phase) must terminate a ringing incoming call")
            XCTAssertEqual(terminal.releasedPrevious?.identity, identity)
            XCTAssertNil(lifecycle.activeSnapshot)
            XCTAssertFalse(lifecycle.hasActiveCall)
            XCTAssertEqual(lifecycle.lastTerminalSnapshot?.phase, phase)
            let commands = prompts.commands(for: terminal)
            XCTAssertTrue(commands.contains(.stopAll))
            XCTAssertFalse(commands.contains(.startLoop(.incomingRingtone)))

            let duplicate = lifecycle.apply(.init(identity: identity, phase: phase, revision: 2))
            XCTAssertEqual(duplicate.disposition, .ignored(.noActiveSession))
            XCTAssertTrue(prompts.commands(for: duplicate).isEmpty)
        }
    }

    func testIncomingAnsweredElsewhereCannotResurrectOrReleaseReplacementEpoch() {
        var lifecycle = CallLifecycleStateMachine()
        let oldIdentity = CallLifecycleSessionIdentity(scopeID: "tenant:user", callID: "incoming", epoch: 1)
        _ = lifecycle.claim(oldIdentity, direction: .incoming)
        let terminal = lifecycle.apply(
            .init(identity: oldIdentity, phase: .ended, revision: 1, reason: "answered_elsewhere")
        )
        XCTAssertTrue(terminal.isApplied)
        XCTAssertEqual(lifecycle.lastTerminalSnapshot?.reason, "answered_elsewhere")
        XCTAssertFalse(lifecycle.hasActiveCall)

        let lateAnswer = lifecycle.apply(.init(identity: oldIdentity, phase: .connected, revision: 2))
        XCTAssertEqual(lateAnswer.disposition, .ignored(.noActiveSession))
        let staleClaim = lifecycle.claim(oldIdentity, direction: .incoming, revision: 3)
        XCTAssertEqual(staleClaim.disposition, .ignored(.staleEpoch))
        XCTAssertNil(lifecycle.activeSnapshot)

        let replacement = CallLifecycleSessionIdentity(scopeID: oldIdentity.scopeID, callID: oldIdentity.callID, epoch: 2)
        XCTAssertTrue(lifecycle.claim(replacement, direction: .incoming).isApplied)
        let oldCleanup = lifecycle.apply(
            .init(identity: oldIdentity, phase: .ended, revision: 4, reason: "answered_elsewhere")
        )
        XCTAssertEqual(oldCleanup.disposition, .ignored(.foreignSession))
        XCTAssertTrue(lifecycle.ownsActiveCall(replacement))
        XCTAssertEqual(lifecycle.activeSnapshot?.phase, .ringing)
    }

    func testOutgoingLifecycleOwnsOnlyNonterminalSessionAndIgnoresDuplicateOrReorderedEvents() throws {
        var lifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let identity = CallLifecycleSessionIdentity(scopeID: "tenant:user", callID: "call-1", epoch: 1)

        let claimed = lifecycle.claim(identity, direction: .outgoing)
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))
        XCTAssertEqual(claimed.current?.phase, .dialing)
        XCTAssertEqual(prompts.commands(for: claimed), [.stopAll, .releasePromptAudioSession])

        let ringing = lifecycle.apply(.init(identity: identity, phase: .ringing, revision: 1))
        XCTAssertEqual(
            prompts.commands(for: ringing),
            [.stopAll, .prepare(.appOwnedCallPrompt), .startLoop(.outgoingRingback)]
        )

        let duplicate = lifecycle.apply(.init(identity: identity, phase: .ringing, revision: 1))
        XCTAssertEqual(duplicate.disposition, .ignored(.staleRevision))
        XCTAssertTrue(prompts.commands(for: duplicate).isEmpty)

        let connected = lifecycle.apply(.init(identity: identity, phase: .connected, revision: 3))
        XCTAssertEqual(
            prompts.commands(for: connected),
            [.stopAll, .prepare(.appOwnedCallPrompt), .playOneShot(.connected, maximumDuration: 1.0)]
        )

        let reorderedBusy = lifecycle.apply(.init(identity: identity, phase: .busy, revision: 2))
        XCTAssertEqual(reorderedBusy.disposition, .ignored(.staleRevision))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))
        XCTAssertTrue(prompts.commands(for: reorderedBusy).isEmpty)

        let ended = lifecycle.apply(.init(identity: identity, phase: .ended, revision: 4))
        XCTAssertFalse(lifecycle.hasActiveCall)
        XCTAssertNil(lifecycle.activeSnapshot)
        XCTAssertEqual(lifecycle.lastTerminalSnapshot?.phase, .ended)
        XCTAssertEqual(
            prompts.commands(for: ended),
            [.stopAll, .prepare(.appOwnedCallPrompt), .playOneShot(.ended, maximumDuration: 1.25)]
        )

        let lateConnected = lifecycle.apply(.init(identity: identity, phase: .connected, revision: 5))
        XCTAssertEqual(lateConnected.disposition, .ignored(.noActiveSession))
        XCTAssertFalse(lifecycle.hasActiveCall)
        XCTAssertTrue(prompts.commands(for: lateConnected).isEmpty)
    }

    func testHigherEpochClaimReplacesOldOwnerAndOldEpochCannotMutateOrReclaim() throws {
        var lifecycle = CallLifecycleStateMachine()
        let oldIdentity = CallLifecycleSessionIdentity(scopeID: "scope", callID: "call-old", epoch: 7)
        let newIdentity = CallLifecycleSessionIdentity(scopeID: "scope", callID: "call-new", epoch: 8)

        _ = lifecycle.claim(oldIdentity, direction: .incoming)
        let replacement = lifecycle.claim(newIdentity, direction: .outgoing)

        XCTAssertEqual(replacement.releasedPrevious?.identity, oldIdentity)
        XCTAssertTrue(lifecycle.ownsActiveCall(newIdentity))
        XCTAssertFalse(lifecycle.ownsActiveCall(oldIdentity))

        let staleTerminal = lifecycle.apply(.init(identity: oldIdentity, phase: .ended, revision: 20))
        XCTAssertEqual(staleTerminal.disposition, .ignored(.foreignSession))
        XCTAssertTrue(lifecycle.ownsActiveCall(newIdentity))

        let staleReclaim = lifecycle.claim(oldIdentity, direction: .incoming, revision: 21)
        XCTAssertEqual(staleReclaim.disposition, .ignored(.staleEpoch))
        XCTAssertTrue(lifecycle.ownsActiveCall(newIdentity))
    }

    func testEveryPreconnectionTerminalPhaseReleasesOwnership() {
        let terminalPhases: [CallLifecyclePhase] = [
            .busy, .rejected, .cancelled, .timeout, .ended, .failure
        ]

        for (offset, phase) in terminalPhases.enumerated() {
            var lifecycle = CallLifecycleStateMachine()
            let identity = CallLifecycleSessionIdentity(callID: "call-\(phase.rawValue)", epoch: UInt64(offset + 1))
            _ = lifecycle.claim(identity, direction: .outgoing)

            let transition = lifecycle.apply(.init(identity: identity, phase: phase, revision: 1))

            XCTAssertTrue(transition.isApplied, "\(phase) must be terminal from dialing")
            XCTAssertFalse(lifecycle.hasActiveCall, "\(phase) must release active ownership")
            XCTAssertEqual(lifecycle.lastTerminalSnapshot?.phase, phase)
        }
    }

    func testInvalidRegressiveTransitionCannotCorruptConnectedSession() throws {
        var lifecycle = CallLifecycleStateMachine()
        let identity = CallLifecycleSessionIdentity(callID: "call-connected", epoch: 1)
        _ = lifecycle.claim(identity, direction: .outgoing)
        _ = lifecycle.apply(.init(identity: identity, phase: .connected, revision: 1))

        let regressive = lifecycle.apply(.init(identity: identity, phase: .ringing, revision: 2))

        XCTAssertEqual(regressive.disposition, .ignored(.invalidTransition))
        XCTAssertEqual(lifecycle.activeSnapshot?.phase, .connected)
        XCTAssertEqual(lifecycle.activeSnapshot?.revision, 1)
    }

    func testIncomingAnswerStopsRingtoneWhileMediaIsStillEstablishing() throws {
        var incomingLifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let incoming = CallLifecycleSessionIdentity(callID: "incoming-answer", epoch: 1)
        _ = prompts.commands(for: incomingLifecycle.claim(incoming, direction: .incoming))

        let answered = incomingLifecycle.apply(
            .init(identity: incoming, phase: .dialing, revision: 1, reason: "answered")
        )

        XCTAssertTrue(answered.isApplied)
        XCTAssertEqual(incomingLifecycle.activeSnapshot?.phase, .dialing)
        XCTAssertFalse(incomingLifecycle.activeSnapshot?.hasEverConnected == true)
        XCTAssertTrue(incomingLifecycle.ownsActiveCall(incoming))
        XCTAssertEqual(prompts.commands(for: answered), [.stopAll, .releasePromptAudioSession])

        var outgoingLifecycle = CallLifecycleStateMachine()
        let outgoing = CallLifecycleSessionIdentity(callID: "outgoing-no-regression", epoch: 1)
        _ = outgoingLifecycle.claim(outgoing, direction: .outgoing)
        _ = outgoingLifecycle.apply(.init(identity: outgoing, phase: .ringing, revision: 1))
        let outgoingRegression = outgoingLifecycle.apply(
            .init(identity: outgoing, phase: .dialing, revision: 2)
        )
        XCTAssertEqual(outgoingRegression.disposition, .ignored(.invalidTransition))
        XCTAssertEqual(outgoingLifecycle.activeSnapshot?.phase, .ringing)
    }

    func testAuthoritativeReconciliationReleasesOwnerMissingFromNonemptyList() throws {
        var lifecycle = CallLifecycleStateMachine()
        let identity = CallLifecycleSessionIdentity(scopeID: "tenant:user", callID: "current", epoch: 9)
        _ = lifecycle.claim(identity, direction: .outgoing, revision: 3)

        let lowRevisionEmpty = lifecycle.reconcile(
            .init(
                scopeID: identity.scopeID,
                observedOwnerEpoch: identity.epoch,
                observedOwnerRevision: 2,
                observedOwnerLocalVersion: 0,
                calls: []
            )
        )
        XCTAssertEqual(lowRevisionEmpty.disposition, .ignored(.staleRevision))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))

        let oldEpochEmpty = lifecycle.reconcile(
            .init(
                scopeID: identity.scopeID,
                observedOwnerEpoch: identity.epoch - 1,
                observedOwnerRevision: 3,
                observedOwnerLocalVersion: 0,
                calls: []
            )
        )
        XCTAssertEqual(oldEpochEmpty.disposition, .ignored(.staleEpoch))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))

        let emptyCallIDTerminal = lifecycle.apply(
            .init(
                identity: .init(scopeID: identity.scopeID, callID: "", epoch: identity.epoch),
                phase: .ended,
                revision: 4
            )
        )
        XCTAssertEqual(emptyCallIDTerminal.disposition, .ignored(.foreignSession))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))

        let wrongCallIDTerminal = lifecycle.apply(
            .init(
                identity: .init(scopeID: identity.scopeID, callID: "wrong", epoch: identity.epoch),
                phase: .ended,
                revision: 4
            )
        )
        XCTAssertEqual(wrongCallIDTerminal.disposition, .ignored(.foreignSession))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))

        let lowRevisionTerminal = lifecycle.apply(
            .init(identity: identity, phase: .ended, revision: 3)
        )
        XCTAssertEqual(lowRevisionTerminal.disposition, .ignored(.staleRevision))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))

        let authoritativeForeignList = lifecycle.reconcile(
            .init(
                scopeID: identity.scopeID,
                observedOwnerEpoch: identity.epoch,
                observedOwnerRevision: 3,
                observedOwnerLocalVersion: 0,
                calls: [.init(callID: "foreign", phase: .ended, revision: 4)]
            )
        )
        XCTAssertTrue(authoritativeForeignList.isApplied)
        XCTAssertEqual(authoritativeForeignList.current?.phase, .ended)
        XCTAssertEqual(authoritativeForeignList.current?.reason, "authoritative_reconciliation_absent")
        XCTAssertFalse(lifecycle.hasActiveCall)

        var emptyLifecycle = CallLifecycleStateMachine()
        let emptyIdentity = CallLifecycleSessionIdentity(scopeID: "tenant:user", callID: "missing", epoch: 10)
        _ = emptyLifecycle.claim(emptyIdentity, direction: .incoming, revision: 5)
        let authoritativeEmpty = emptyLifecycle.reconcile(
            .init(
                scopeID: emptyIdentity.scopeID,
                observedOwnerEpoch: emptyIdentity.epoch,
                observedOwnerRevision: 5,
                observedOwnerLocalVersion: 0,
                calls: []
            )
        )
        XCTAssertTrue(authoritativeEmpty.isApplied)
        XCTAssertFalse(emptyLifecycle.hasActiveCall)
    }

    func testLocalMediaClockCannotMakeNewerServerTerminalLookStale() throws {
        var lifecycle = CallLifecycleStateMachine()
        let identity = CallLifecycleSessionIdentity(scopeID: "tenant:user", callID: "dual-clock", epoch: 1)
        _ = lifecycle.claim(identity, direction: .incoming, revision: 0)

        XCTAssertTrue(lifecycle.apply(.init(identity: identity, phase: .dialing)).isApplied)
        XCTAssertTrue(lifecycle.apply(.init(identity: identity, phase: .connected)).isApplied)
        XCTAssertTrue(lifecycle.apply(.init(identity: identity, phase: .reconnecting)).isApplied)
        XCTAssertTrue(lifecycle.apply(.init(identity: identity, phase: .connected)).isApplied)
        XCTAssertEqual(lifecycle.activeSnapshot?.revision, 0)
        XCTAssertEqual(lifecycle.activeSnapshot?.localVersion, 4)

        let serverEnded = lifecycle.apply(.init(identity: identity, phase: .ended, revision: 1))
        XCTAssertTrue(serverEnded.isApplied)
        XCTAssertFalse(lifecycle.hasActiveCall)
    }

    func testReconciliationResponseStartedBeforeLocalMutationCannotReleaseOwner() throws {
        var lifecycle = CallLifecycleStateMachine()
        let identity = CallLifecycleSessionIdentity(scopeID: "tenant:user", callID: "raced", epoch: 1)
        _ = lifecycle.claim(identity, direction: .outgoing, revision: 2)
        let observed = try XCTUnwrap(lifecycle.activeSnapshot)
        _ = lifecycle.apply(.init(identity: identity, phase: .connected))

        let staleResponse = lifecycle.reconcile(
            .init(
                scopeID: identity.scopeID,
                observedOwnerEpoch: identity.epoch,
                observedOwnerRevision: observed.revision,
                observedOwnerLocalVersion: observed.localVersion,
                calls: []
            )
        )
        XCTAssertEqual(staleResponse.disposition, .ignored(.staleRevision))
        XCTAssertTrue(lifecycle.ownsActiveCall(identity))
    }

    func testReconnectDoesNotReplayConnectedCue() throws {
        var lifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let identity = CallLifecycleSessionIdentity(callID: "call-recover", epoch: 1)
        _ = prompts.commands(for: lifecycle.claim(identity, direction: .outgoing))

        let firstConnected = lifecycle.apply(.init(identity: identity, phase: .connected, revision: 1))
        XCTAssertTrue(prompts.commands(for: firstConnected).contains(.playOneShot(.connected, maximumDuration: 1.0)))

        let reconnecting = lifecycle.apply(.init(identity: identity, phase: .reconnecting, revision: 2))
        XCTAssertEqual(prompts.commands(for: reconnecting), [.stopAll, .releasePromptAudioSession])

        let recovered = lifecycle.apply(.init(identity: identity, phase: .connected, revision: 3))
        XCTAssertEqual(prompts.commands(for: recovered), [.stopAll, .releasePromptAudioSession])
        XCTAssertEqual(lifecycle.activeSnapshot?.phase, .connected)
        XCTAssertTrue(lifecycle.activeSnapshot?.hasEverConnected == true)
    }

    func testIncomingRingtoneUsesSystemPolicyAndBusyToneIsBounded() throws {
        var incomingLifecycle = CallLifecycleStateMachine()
        var incomingPrompts = CallPromptCoordinator()
        let incoming = CallLifecycleSessionIdentity(callID: "incoming", epoch: 1)

        let claim = incomingLifecycle.claim(incoming, direction: .incoming)
        XCTAssertEqual(
            incomingPrompts.commands(for: claim),
            [.stopAll, .prepare(.incomingRespectingSystemPolicy), .startLoop(.incomingRingtone)]
        )

        var outgoingLifecycle = CallLifecycleStateMachine()
        var outgoingPrompts = CallPromptCoordinator()
        let outgoing = CallLifecycleSessionIdentity(callID: "outgoing", epoch: 1)
        _ = outgoingPrompts.commands(for: outgoingLifecycle.claim(outgoing, direction: .outgoing))
        _ = outgoingPrompts.commands(
            for: outgoingLifecycle.apply(.init(identity: outgoing, phase: .ringing, revision: 1))
        )
        let busy = outgoingLifecycle.apply(.init(identity: outgoing, phase: .busy, revision: 2))

        XCTAssertFalse(outgoingLifecycle.hasActiveCall)
        XCTAssertEqual(
            outgoingPrompts.commands(for: busy),
            [.stopAll, .prepare(.appOwnedCallPrompt), .playOneShot(.busy, maximumDuration: 2.5)]
        )
    }

    func testBackgroundInterruptionAndRouteChangesCannotLeaveOrReplayGhostAudio() throws {
        var lifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let identity = CallLifecycleSessionIdentity(callID: "call-audio", epoch: 1)
        _ = prompts.commands(for: lifecycle.claim(identity, direction: .outgoing))
        _ = prompts.commands(for: lifecycle.apply(.init(identity: identity, phase: .ringing, revision: 1)))

        XCTAssertEqual(
            prompts.commands(for: .applicationDidEnterBackground, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .releasePromptAudioSession]
        )
        XCTAssertTrue(prompts.isSuppressed)

        XCTAssertEqual(
            prompts.commands(
                for: .audioRouteChanged(.newDeviceAvailable),
                activeSnapshot: lifecycle.activeSnapshot
            ),
            [.stopAll, .releasePromptAudioSession]
        )

        XCTAssertEqual(
            prompts.commands(for: .applicationDidBecomeActive, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .prepare(.appOwnedCallPrompt), .startLoop(.outgoingRingback)]
        )

        XCTAssertEqual(
            prompts.commands(for: .interruptionBegan, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .releasePromptAudioSession]
        )
        XCTAssertEqual(
            prompts.commands(
                for: .interruptionEnded(shouldResume: false),
                activeSnapshot: lifecycle.activeSnapshot
            ),
            [.stopAll, .releasePromptAudioSession]
        )
        XCTAssertTrue(prompts.isSuppressed)
    }

    func testRouteReconciliationRestartsOnlyWaitingLoopsAndTerminationIsFinal() throws {
        var lifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let identity = CallLifecycleSessionIdentity(callID: "call-terminal", epoch: 1)
        _ = prompts.commands(for: lifecycle.claim(identity, direction: .outgoing))
        _ = prompts.commands(for: lifecycle.apply(.init(identity: identity, phase: .connected, revision: 1)))

        XCTAssertEqual(
            prompts.commands(
                for: .audioRouteChanged(.newDeviceAvailable),
                activeSnapshot: lifecycle.activeSnapshot
            ),
            [.stopAll, .releasePromptAudioSession],
            "route changes must not replay the connected one-shot"
        )

        XCTAssertEqual(
            prompts.commands(for: .applicationWillTerminate, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .releasePromptAudioSession]
        )
        XCTAssertTrue(prompts.isTerminated)

        XCTAssertEqual(
            prompts.commands(for: .applicationDidBecomeActive, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .releasePromptAudioSession]
        )

        let ended = lifecycle.apply(.init(identity: identity, phase: .ended, revision: 2))
        XCTAssertTrue(prompts.commands(for: ended).isEmpty)
    }

    func testOldRouteRemovalStopsWaitingLoopWithoutMovingItToSpeaker() throws {
        var lifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let identity = CallLifecycleSessionIdentity(callID: "call-private-route", epoch: 1)
        _ = prompts.commands(for: lifecycle.claim(identity, direction: .outgoing))
        _ = prompts.commands(for: lifecycle.apply(.init(identity: identity, phase: .ringing, revision: 1)))

        XCTAssertEqual(
            prompts.commands(
                for: .audioRouteChanged(.oldDeviceUnavailable),
                activeSnapshot: lifecycle.activeSnapshot
            ),
            [.stopAll, .releasePromptAudioSession]
        )
        XCTAssertTrue(prompts.isSuppressed)

        XCTAssertEqual(
            prompts.commands(
                for: .audioRouteChanged(.newDeviceAvailable),
                activeSnapshot: lifecycle.activeSnapshot
            ),
            [.stopAll, .releasePromptAudioSession],
            "a subsequent route callback must not silently override the privacy pause"
        )
    }

    func testCallKitAudioSessionCallbacksOnlyFencePromptPlayback() throws {
        var lifecycle = CallLifecycleStateMachine()
        var prompts = CallPromptCoordinator()
        let identity = CallLifecycleSessionIdentity(callID: "call-callkit", epoch: 1)
        _ = prompts.commands(for: lifecycle.claim(identity, direction: .incoming))

        XCTAssertEqual(
            prompts.commands(for: .callKitAudioSessionDeactivated, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .releasePromptAudioSession]
        )
        XCTAssertTrue(prompts.isSuppressed)

        XCTAssertEqual(
            prompts.commands(for: .callKitAudioSessionActivated, activeSnapshot: lifecycle.activeSnapshot),
            [.stopAll, .releasePromptAudioSession],
            "CallKit activation must not replay the incoming ringtone"
        )
        XCTAssertFalse(prompts.isSuppressed)
    }

    func testReleaseActiveUsesTerminalTransitionAndCannotDoubleRelease() throws {
        var lifecycle = CallLifecycleStateMachine()
        let identity = CallLifecycleSessionIdentity(callID: "call-release", epoch: 1)
        _ = lifecycle.claim(identity, direction: .incoming, revision: 9)

        let release = lifecycle.releaseActive(as: .failure, reason: "media_services_lost")
        XCTAssertTrue(release.isApplied)
        XCTAssertEqual(release.current?.revision, 9)
        XCTAssertEqual(release.current?.reason, "media_services_lost")
        XCTAssertFalse(lifecycle.hasActiveCall)

        let duplicateRelease = lifecycle.releaseActive(as: .ended)
        XCTAssertEqual(duplicateRelease.disposition, .ignored(.noActiveSession))

        var maximumRevisionLifecycle = CallLifecycleStateMachine()
        let maximumRevisionIdentity = CallLifecycleSessionIdentity(callID: "call-max-revision", epoch: 1)
        _ = maximumRevisionLifecycle.claim(
            maximumRevisionIdentity,
            direction: .outgoing,
            revision: .max
        )
        let maximumRevisionRelease = maximumRevisionLifecycle.releaseActive(as: .failure)
        XCTAssertTrue(maximumRevisionRelease.isApplied)
        XCTAssertEqual(maximumRevisionRelease.current?.revision, .max)
        XCTAssertFalse(maximumRevisionLifecycle.hasActiveCall)

        var connectedLifecycle = CallLifecycleStateMachine()
        let connectedIdentity = CallLifecycleSessionIdentity(callID: "call-invalid-release", epoch: 1)
        _ = connectedLifecycle.claim(connectedIdentity, direction: .outgoing)
        _ = connectedLifecycle.apply(.init(identity: connectedIdentity, phase: .connected, revision: 1))
        let invalidRelease = connectedLifecycle.releaseActive(as: .busy)
        XCTAssertEqual(invalidRelease.disposition, .ignored(.invalidTransition))
        XCTAssertTrue(connectedLifecycle.ownsActiveCall(connectedIdentity))
    }

    func testDirectionAwarePeerResolverSelectsOutgoingAcceptedWinnerAcrossSameUIDDevices() throws {
        let call = RemoteRTCCall(
            id: "call-outgoing-winner",
            status: "accepted",
            callerUID: "ios-caller",
            calleeUID: "web-user",
            callerDevice: RemoteRTCDevice(uid: "ios-caller", deviceID: "ios-device", deviceType: "ios"),
            calleeDevice: RemoteRTCDevice(uid: "web-user", deviceID: "web-winner", deviceType: "web"),
            acceptedDevice: RemoteRTCDevice(uid: "web-user", deviceID: "web-winner", deviceType: "web")
        )
        let selfParticipant = RemoteRTCRoomParticipant(
            uid: "ios-caller",
            deviceID: "ios-device",
            deviceType: "ios",
            role: "caller"
        )
        let loser = RemoteRTCRoomParticipant(
            uid: "web-user",
            deviceID: "web-loser",
            deviceType: "web",
            role: "callee"
        )
        let winner = RemoteRTCRoomParticipant(
            uid: "web-user",
            deviceID: "web-winner",
            deviceType: "web",
            role: "callee"
        )

        let resolved = RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: ["ios-caller"],
            selfParticipant: selfParticipant,
            explicitPeer: loser,
            participants: [selfParticipant, loser, winner]
        )

        XCTAssertEqual(resolved?.direction, .outgoing)
        XCTAssertEqual(resolved?.participant, winner)
        XCTAssertEqual(resolved?.source, "accepted_device")
    }

    func testDirectionAwarePeerResolverWaitsWhenOnlySameUIDLoserHasJoined() {
        let call = RemoteRTCCall(
            id: "call-outgoing-wait",
            status: "accepted",
            callerUID: "ios-caller",
            calleeUID: "web-user",
            acceptedDevice: RemoteRTCDevice(uid: "web-user", deviceID: "web-winner", deviceType: "web")
        )
        let selfParticipant = RemoteRTCRoomParticipant(
            uid: "ios-caller",
            deviceID: "ios-device",
            deviceType: "ios",
            role: "caller"
        )
        let loser = RemoteRTCRoomParticipant(
            uid: "web-user",
            deviceID: "web-loser",
            deviceType: "web",
            role: "callee"
        )

        XCTAssertNil(RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: ["ios-caller"],
            selfParticipant: selfParticipant,
            explicitPeer: loser,
            participants: [selfParticipant, loser]
        ))
    }

    func testDirectionAwarePeerResolverIncomingUsesCallerDeviceAndNeverLocalWinner() throws {
        let call = RemoteRTCCall(
            id: "call-incoming-caller",
            status: "accepted",
            callerUID: "web-caller",
            calleeUID: "ios-callee",
            callerDevice: RemoteRTCDevice(uid: "web-caller", deviceID: "web-caller-device", deviceType: "web"),
            calleeDevice: RemoteRTCDevice(uid: "ios-callee", deviceID: "ios-winner", deviceType: "ios"),
            acceptedDevice: RemoteRTCDevice(uid: "ios-callee", deviceID: "ios-winner", deviceType: "ios")
        )
        let selfParticipant = RemoteRTCRoomParticipant(
            uid: "ios-callee",
            deviceID: "ios-winner",
            deviceType: "ios",
            role: "callee"
        )
        let staleWebDevice = RemoteRTCRoomParticipant(
            uid: "web-caller",
            deviceID: "web-stale-device",
            deviceType: "web",
            role: "caller"
        )
        let caller = RemoteRTCRoomParticipant(
            uid: "web-caller",
            deviceID: "web-caller-device",
            deviceType: "web",
            role: "caller"
        )

        let resolved = RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: ["ios-callee"],
            selfParticipant: selfParticipant,
            explicitPeer: staleWebDevice,
            participants: [selfParticipant, staleWebDevice, caller]
        )

        XCTAssertEqual(resolved?.direction, .incoming)
        XCTAssertEqual(resolved?.participant, caller)
        XCTAssertEqual(resolved?.source, "caller_device")
        XCTAssertNotEqual(resolved?.participant.deviceID, selfParticipant.deviceID)
    }

    func testDirectionAwarePeerResolverDoesNotChooseFirstOfAmbiguousSameUIDDevices() {
        let call = RemoteRTCCall(
            id: "call-ambiguous-peer",
            status: "accepted",
            callerUID: "ios-caller",
            calleeUID: "web-user"
        )
        let selfParticipant = RemoteRTCRoomParticipant(
            uid: "ios-caller",
            deviceID: "ios-device",
            deviceType: "ios",
            role: "caller"
        )
        let first = RemoteRTCRoomParticipant(uid: "web-user", deviceID: "web-a", deviceType: "web", role: "callee")
        let second = RemoteRTCRoomParticipant(uid: "web-user", deviceID: "web-b", deviceType: "web", role: "callee")

        XCTAssertNil(RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: ["ios-caller"],
            selfParticipant: selfParticipant,
            explicitPeer: nil,
            participants: [selfParticipant, first, second]
        ))
    }
}

@MainActor
final class RTCDuplicateRingingHandlerTests: XCTestCase {
    private let callID = "fixture-ringing-call"

    func testSameCallRealtimeReplayDoesNotRejectOrEndPresentedCall() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.phase, .ringing)
        XCTAssertTrue(state.callStore.hasTruthfulCall)
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertTrue(system.ends.isEmpty)

        // Enter the production realtime dispatcher, not receiveIncomingVoiceCall.
        state.debugHandleRealtimeEnvelopeForTesting(ringing(version: 2))
        try await drainTerminalCompensation(state)

        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, callID)
        XCTAssertTrue(system.ends.isEmpty, "same-ID replay must not issue CallKit endCall")
        XCTAssertTrue(transport.rejectPaths.isEmpty, "same-ID replay must not POST /reject")
    }

    func testRealtimeThenHTTPReplayUsesSharedHandlerWithoutRejectingSameCall() async throws {
        XCTAssertFalse(JHTRuntimeFeatureFlags.disableRTCRuntime,
                       "enable RTC runtime for actual HTTP refresh entrypoint coverage")
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        XCTAssertTrue(state.callStore.hasTruthfulCall)

        // Runs actual API GET -> RemoteRTCCallEvent decoding -> shared handler -> ACK.
        await state.refreshRTCCallEventsForTesting()
        try await drainTerminalCompensation(state)

        XCTAssertTrue(transport.paths.contains("/api/rtc/calls/events"))
        XCTAssertTrue(transport.paths.contains("/api/rtc/calls/events/ack"))
        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
        XCTAssertTrue(system.ends.isEmpty)
        XCTAssertTrue(transport.rejectPaths.isEmpty)
    }

    func testDelayedRingingDoesNotRejectCallAfterRealAcceptAndJoin() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        state.acceptIncomingVoiceCall()
        let deadline = Date().addingTimeInterval(5)
        while !transport.participantGate.entered, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(transport.participantGate.entered)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        XCTAssertNil(state.incomingVoiceCall)
        state.debugHandleRealtimeEnvelopeForTesting(ringing(version: 2))
        try await drainTerminalCompensation(state)
        XCTAssertTrue(system.ends.isEmpty)
        XCTAssertTrue(transport.rejectPaths.isEmpty)
        XCTAssertEqual(state.activeVoiceCall?.callID, callID)
        state.endActiveVoiceCall()
        transport.participantGate.release()
        while (state.activeVoiceCall != nil || state.incomingCallAnswerMode != nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(state.activeVoiceCall)
        XCTAssertNil(state.incomingCallAnswerMode)
    }

    func testDifferentCallStillReceivesBusyRejectWithoutEndingCurrentIncomingCall() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        state.debugHandleRealtimeEnvelopeForTesting(ringing(callID: "fixture-competing-call"))
        try await drainTerminalCompensation(state)

        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.callStore.activeLifecycleSnapshot?.identity.callID, callID)
        XCTAssertEqual(system.ends.map(\.callID), ["fixture-competing-call"])
        XCTAssertEqual(system.ends.map(\.reason), ["client_busy"])
        XCTAssertEqual(transport.rejectPaths, ["/api/rtc/calls/fixture-competing-call/reject"])
    }

    func testReceiveIncomingDirectlyHasSameCallGuardButIsNotSharedHandlerCoverage() async throws {
        let (state, system, transport) = makeFixture()
        state.debugHandleRealtimeEnvelopeForTesting(ringing())
        let first = try XCTUnwrap(state.incomingVoiceCall)
        state.receiveIncomingVoiceCall(from: first.caller, callID: callID,
                                       roomID: "fixture-room", stateVersion: 2,
                                       systemOwnsRingtone: true)
        try await drainTerminalCompensation(state)
        XCTAssertEqual(state.incomingVoiceCall?.id, first.id)
        XCTAssertEqual(state.incomingVoiceCall?.stateVersion, 2)
        XCTAssertTrue(system.ends.isEmpty)
        XCTAssertTrue(transport.rejectPaths.isEmpty)
    }

    private func drainTerminalCompensation(_ state: AppState) async throws {
        // enqueueRTCTerminalCompensation inserts in-flight synchronously BEFORE
        // scheduling its Task. This avoids an arbitrary negative-request sleep.
        let deadline = Date().addingTimeInterval(2)
        while state.rtcTerminalCompensationsInFlightCountForTesting > 0 {
            if Date() >= deadline { throw RingingFixtureError.compensationDidNotDrain }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeFixture() -> (AppState, RecordingRingingSystem, RecordingRingingHTTPTransport) {
        let transport = RecordingRingingHTTPTransport()
        let system = RecordingRingingSystem(presented: [callID])
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                              tenantBase: URL(string: "https://tenant.example.test")!,
                              imBase: URL(string: "https://im.example.test")!,
                              httpTransport: transport, wireCodec: JSONWireCodec())
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
                             videoMediaClient: NoopVideoMediaClient(), voiceCallSystem: system,
                             microphonePermissionDecisionOverride: { true },
                             apiContextOverride: IMAPIContext(
                                platformToken: "fixture-platform-token", accountID: "fixture-account",
                                tenantID: "fixture-tenant", imUID: "fixture-callee",
                                imToken: "fixture-im-token", platformAuthSession: nil,
                                tenantAuthSession: nil, appID: "ios-main", deviceID: "fixture-device"))
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(maxBytes: 20971520, maxMB: 20, source: "test",
            messageRecallMaxMinutes: 120, voiceCallEnabled: true, videoCallEnabled: true,
            readReceiptsEnabled: true, groupAdminDeleteMessageEnabled: false)
        state.currentUser = IMUser(id: "fixture-callee", name: "Fixture callee", title: "",
                                   department: "", phone: "", email: "", status: "在线",
                                   enterprise: "", avatarSeed: 0, badges: [])
        return (state, system, transport)
    }

    private func ringing(callID: String? = nil, version: Int = 1) -> RealtimeEnvelope {
        RealtimeEnvelope(type: "rtc.call.ringing", requestID: UUID().uuidString, payload: [
            "call_id": .string(callID ?? self.callID), "status": .string("ringing"),
            "caller_uid": .string("fixture-caller"), "callee_uid": .string("fixture-callee"),
            "room_id": .string("fixture-room"), "state_version": .string(String(version)),
            "call_type": .string("audio")
        ])
    }
}

private enum RingingFixtureError: Error { case unexpectedRequest, compensationDidNotDrain }

private final class RecordingRingingHTTPTransport: HTTPTransport, @unchecked Sendable {
    let participantGate = SetupRaceGate()
    private let configurationTransport = SetupRaceHTTPTransport(status: "ringing", deviceAuthority: false)
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var paths: [String] { lock.withLock { captured.compactMap { $0.url?.path } } }
    var rejectPaths: [String] { paths.filter { $0.hasSuffix("/reject") } }

    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        lock.withLock { captured.append(request) }
        let path = request.url?.path ?? ""
        let body: String
        if path == "/api/rtc/calls/events", request.httpMethod == "GET" {
            body = #"{"ok":true,"data":{"events":[{"id":"fixture-event","notification_id":"fixture-notification","type":"rtc.call.ringing","payload":{"call_id":"fixture-ringing-call","status":"ringing","caller_uid":"fixture-caller","callee_uid":"fixture-callee","room_id":"fixture-room","state_version":2,"call_type":"audio"}}]}}"#
        } else if path == "/api/rtc/calls/fixture-ringing-call/accept" {
            body = #"{"ok":true,"data":{"call":{"id":"fixture-ringing-call","room_id":"fixture-room","status":"accepted","caller_uid":"fixture-caller","callee_uid":"fixture-callee","call_type":"audio","state_version":2},"rtc_token":"fixture-rtc-token"}}"#
        } else if path == "/api/rtc/rooms/fixture-room/join" {
            body = #"{"ok":true,"data":{"room_id":"fixture-room","rtc_token":"fixture-rtc-token","media":{"owt_base_url":"https://rtc.example.test","ice_servers":[]},"participants":[]}}"#
        } else if path == "/api/rtc/rooms/fixture-room/participants" {
            await participantGate.wait()
            body = #"{"ok":true,"data":{"participants":[]}}"#
        } else if path == "/api/tenant/files/config" || path == "/api/rtc/provider" {
            return try await configurationTransport.data(for: request)
        } else if request.httpMethod == "POST",
                  path == "/api/rtc/calls/events/ack" || path.hasSuffix("/reject") || path.hasSuffix("/hangup") {
            body = #"{"ok":true,"data":{}}"#
        } else { throw RingingFixtureError.unexpectedRequest }
        return HTTPTransportResult(data: Data(body.utf8), isHTTPResponse: true,
                                   statusCode: 200).resolvingResponseURL(request.url)
    }
    func upload(for request: URLRequest, from data: Data,
                delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw RingingFixtureError.unexpectedRequest
    }
}

private final class RecordingRingingSystem: VoiceCallSystemIntegrating, @unchecked Sendable {
    struct End: Equatable { let callID: String; let reason: String }
    let events = AsyncStream<VoiceCallSystemEvent> { $0.finish() }
    private let lock = NSLock()
    private var presented: Set<String>
    private var recordedEnds: [End] = []
    var ends: [End] { lock.withLock { recordedEnds } }
    init(presented: Set<String>) { self.presented = presented }
    func start() {}
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool { false }
    func setMuted(callID: String, isMuted: Bool) {}
    func hasPresentedCall(callID: String) -> Bool { lock.withLock { presented.contains(callID) } }
    func clearPresentedCall(callID: String) { lock.withLock { _ = presented.remove(callID) } }
    func endCall(callID: String, reason: String) {
        lock.withLock {
            recordedEnds.append(End(callID: callID, reason: reason))
            presented.remove(callID)
        }
    }
}

@MainActor
final class RTCCallSetupReconciliationTests: XCTestCase {
    func testRingingListStartedBeforeVoiceSetupCannotCancelOwnedJoin() async throws {
        try await assertListRace(status: "ringing", deviceAuthority: true, suspendCreate: false)
    }

    func testAcceptedListStartedBeforeVoiceSetupCannotHangupOwnedJoin() async throws {
        try await assertListRace(status: "accepted", deviceAuthority: true, suspendCreate: false)
    }

    func testListReturningBeforeCreateResponseDoesNotCancelStartingCall() async throws {
        try await assertListRace(status: "ringing", deviceAuthority: true, suspendCreate: true)
    }

    func testCurrentPublicListWithoutDeviceAuthorityDoesNotTakeColdLaunchPath() async throws {
        try await assertListRace(status: "ringing", deviceAuthority: false, suspendCreate: false)
    }

    func testTrueColdLaunchStillCancelsOwnedDeviceRingingCall() async throws {
        try await assertColdLaunch(status: "ringing", action: "cancel")
    }

    func testTrueColdLaunchStillHangsUpOwnedDeviceAcceptedCall() async throws {
        try await assertColdLaunch(status: "accepted", action: "hangup")
    }

    private func assertListRace(status: String, deviceAuthority: Bool, suspendCreate: Bool) async throws {
        XCTAssertFalse(JHTRuntimeFeatureFlags.disableRTCRuntime)
        let transport = SetupRaceHTTPTransport(status: status, deviceAuthority: deviceAuthority)
        let (state, system, peer) = makeFixture(transport)
        // A refresh already in flight is allowed by the periodic loop's starting
        // guard. The list response is resumed only after real create/join begins.
        let refresh = Task { await state.refreshRTCCallsForTesting() }
        do {
            try await eventually { transport.listGate.entered }
            XCTAssertFalse(state.isStartingVoiceCall)
            if !suspendCreate { transport.createGate.release() }
            state.startOutgoingVoiceCall(to: peer)
            try await eventually { suspendCreate ? transport.createGate.entered : transport.joinGate.entered }
            XCTAssertTrue(state.isStartingVoiceCall)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 1)
            XCTAssertEqual(state.directCallTrackingCountsForTesting.resourceOwners, suspendCreate ? 0 : 1)
            XCTAssertNil(state.callStore.activeLifecycleSnapshot)
            XCTAssertNil(state.activeVoiceCall)
            transport.listGate.release()
            await refresh.value
            try await eventually { state.rtcTerminalCompensationsInFlightCountForTesting == 0 }
            XCTAssertTrue(system.ends.isEmpty, "a current local setup is not a cold launch orphan")
            XCTAssertTrue(transport.terminalPaths.isEmpty, "list reconciliation must not cancel or hang up the setup")
            // Complete the original real setup; a fixture failure must not leave
            // its continuations, audio session or outgoing watchdog alive.
            transport.createGate.release()
            transport.joinGate.release()
            try await eventually { !state.isStartingVoiceCall }
            XCTAssertEqual(state.activeVoiceCall?.callID, "setup-race-call")
            state.endActiveVoiceCall()
            try await eventually { state.activeVoiceCall == nil && !state.isEndingActiveCall }
        } catch {
            transport.listGate.release()
            transport.createGate.release()
            transport.joinGate.release()
            await refresh.value
            try? await eventually { !state.isStartingVoiceCall }
            state.endActiveVoiceCall()
            try? await eventually { state.activeVoiceCall == nil && !state.isEndingActiveCall }
            throw error
        }
    }

    private func assertColdLaunch(status: String, action: String) async throws {
        let transport = SetupRaceHTTPTransport(status: status, deviceAuthority: true)
        let (state, system, _) = makeFixture(transport)
        transport.listGate.release()
        await state.refreshRTCCallsForTesting()
        try await eventually { state.rtcTerminalCompensationsInFlightCountForTesting == 0 }
        XCTAssertEqual(state.directCallTrackingCountsForTesting.attempts, 0)
        XCTAssertEqual(transport.terminalPaths, ["/api/rtc/calls/setup-race-call/\(action)"])
        XCTAssertEqual(system.ends.map(\.callID), ["setup-race-call"])
        XCTAssertNil(state.activeVoiceCall)
    }

    private func makeFixture(_ transport: SetupRaceHTTPTransport) -> (AppState, RecordingRingingSystem, IMUser) {
        let system = RecordingRingingSystem(presented: [])
        let api = IMAPIClient(platformBase: URL(string: "https://platform.example.test")!,
                              tenantBase: URL(string: "https://tenant.example.test")!,
                              imBase: URL(string: "https://im.example.test")!, httpTransport: transport)
        let state = AppState(api: api, voiceMediaClient: NoopVoiceMediaClient(),
                             videoMediaClient: NoopVideoMediaClient(), voiceCallSystem: system,
                             microphonePermissionDecisionOverride: { true },
                             apiContextOverride: IMAPIContext(
                                platformToken: "fixture-platform-token", accountID: "fixture-account",
                                tenantID: "fixture-tenant", imUID: "fixture-caller", imToken: "fixture-im-token",
                                platformAuthSession: nil, tenantAuthSession: nil,
                                appID: "ios-main", deviceID: "fixture-device"))
        func user(_ id: String) -> IMUser {
            IMUser(id: id, name: id, title: "", department: "", phone: "", email: "",
                   status: "在线", enterprise: "", avatarSeed: 0, badges: [])
        }
        let peer = user("fixture-callee")
        state.currentUser = user("fixture-caller")
        state.contacts = [peer]
        state.voiceMediaClientAvailableOverride = true
        state.fileUploadConfig = FileUploadConfig(maxBytes: 20971520, maxMB: 20, source: "test",
            messageRecallMaxMinutes: 120, voiceCallEnabled: true, videoCallEnabled: true,
            readReceiptsEnabled: true, groupAdminDeleteMessageEnabled: false)
        return (state, system, peer)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw SetupRaceError.conditionTimedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private enum SetupRaceError: Error { case conditionTimedOut, unexpectedRequest }

private final class SetupRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                didEnter = true
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}

private final class SetupRaceHTTPTransport: HTTPTransport, @unchecked Sendable {
    let listGate = SetupRaceGate()
    let createGate = SetupRaceGate()
    let joinGate = SetupRaceGate()
    private let status: String
    private let deviceAuthority: Bool
    private let lock = NSLock()
    private var paths: [String] = []
    var terminalPaths: [String] {
        lock.withLock { paths.filter { $0.hasSuffix("/cancel") || $0.hasSuffix("/hangup") } }
    }
    init(status: String, deviceAuthority: Bool) {
        self.status = status
        self.deviceAuthority = deviceAuthority
    }
    private func call(status: String) -> [String: Any] {
        var value: [String: Any] = ["id": "setup-race-call", "room_id": "setup-race-room",
            "caller_uid": "fixture-caller", "callee_uid": "fixture-callee", "status": status,
            "call_type": "audio", "state_version": 1]
        // Explicit synthetic activation condition: current server's public JSON
        // omits device authority. This case is not evidence of the user's live A/B.
        if deviceAuthority { value["caller_device"] = ["device_id": "fixture-device"] }
        return value
    }
    func data(for request: URLRequest) async throws -> HTTPTransportResult {
        let path = request.url?.path ?? ""
        lock.withLock { paths.append(path) }
        let data: [String: Any]
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/api/rtc/calls"):
            await listGate.wait()
            data = ["calls": [call(status: status)]]
        case ("POST", "/api/rtc/calls"):
            await createGate.wait()
            data = ["call": call(status: "ringing"), "rtc_token": "fixture-rtc-token"]
        case (_, "/api/rtc/rooms/setup-race-room/join"):
            await joinGate.wait()
            data = ["room_id": "setup-race-room", "rtc_token": "fixture-rtc-token",
                    "media": ["owt_base_url": "https://rtc.example.test", "ice_servers": []], "participants": []]
        case (_, "/api/tenant/files/config"):
            data = ["file_upload_max_bytes": 20971520, "max_mb": 20, "source": "test",
                    "message_recall_max_minutes": 120, "voice_call_enabled": true,
                    "video_call_enabled": true, "read_receipts_enabled": true, "group_admin_delete_message_enabled": false]
        case (_, "/api/rtc/provider"):
            data = ["call_types": ["audio", "video"], "voice_call_enabled": true,
                    "video_call_enabled": true, "video_supported": true, "capabilities_version": "video-call-v1",
                    "media_plane_configured": true, "ice_servers_configured": true]
        default:
            guard path.hasSuffix("/cancel") || path.hasSuffix("/hangup") else {
                throw SetupRaceError.unexpectedRequest
            }
            data = [:]
        }
        return HTTPTransportResult(data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]),
            isHTTPResponse: true, statusCode: 200).resolvingResponseURL(request.url)
    }
    func upload(for request: URLRequest, from data: Data, delegate: URLSessionTaskDelegate?) async throws -> HTTPTransportResult {
        throw SetupRaceError.unexpectedRequest
    }
}

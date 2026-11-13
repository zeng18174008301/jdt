import XCTest
@testable import WenDaTong

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

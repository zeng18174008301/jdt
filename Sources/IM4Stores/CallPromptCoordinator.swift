// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Foundation
import IM4Domain

public struct CallPromptCoordinator: Sendable {
    public init() {}
    public private(set) var lastRenderedTransitionSerial: UInt64 = 0
    public private(set) var isSuppressed = false
    public private(set) var isTerminated = false

    public mutating func commands(for transition: CallLifecycleTransition) -> [CallPromptCommand] {
        guard transition.isApplied,
              transition.serial > lastRenderedTransitionSerial,
              !isTerminated else {
            return []
        }
        lastRenderedTransitionSerial = transition.serial

        guard !isSuppressed, let snapshot = transition.current else {
            return cleanupCommands
        }

        if snapshot.phase == .connected,
           transition.previous?.hasEverConnected == true {
            return cleanupCommands
        }

        return commandsForFreshTransition(snapshot)
    }

    /// All suspension and route events stop app-owned playback first. Only waiting loops may be
    /// reconstructed from a currently active truthful snapshot; one-shot cues are never replayed.
    public mutating func commands(
        for event: CallPromptEnvironmentEvent,
        activeSnapshot: CallLifecycleSnapshot?
    ) -> [CallPromptCommand] {
        switch event {
        case .applicationDidEnterBackground, .interruptionBegan:
            isSuppressed = true
            return cleanupCommands
        case .applicationDidBecomeActive:
            guard !isTerminated else { return cleanupCommands }
            isSuppressed = false
            return restartWaitingLoopIfNeeded(activeSnapshot)
        case let .interruptionEnded(shouldResume):
            guard !isTerminated else { return cleanupCommands }
            isSuppressed = !shouldResume
            return shouldResume ? restartWaitingLoopIfNeeded(activeSnapshot) : cleanupCommands
        case .audioRouteChanged(.oldDeviceUnavailable):
            // Apple recommends not automatically moving private headphone playback to a newly
            // exposed route. A later explicit activation or lifecycle transition may resume it.
            isSuppressed = true
            return cleanupCommands
        case .audioRouteChanged(.newDeviceAvailable),
             .audioRouteChanged(.reconfiguration),
             .mediaServicesReset:
            guard !isTerminated, !isSuppressed else { return cleanupCommands }
            return restartWaitingLoopIfNeeded(activeSnapshot)
        case .callKitAudioSessionActivated:
            guard !isTerminated else { return cleanupCommands }
            isSuppressed = false
            // CallKit activation hands the audio session to call media. Do not reconstruct a
            // ringtone or any one-shot cue from this callback.
            return cleanupCommands
        case .callKitAudioSessionDeactivated:
            isSuppressed = true
            return cleanupCommands
        case .applicationWillTerminate:
            isTerminated = true
            isSuppressed = true
            return cleanupCommands
        }
    }

    private var cleanupCommands: [CallPromptCommand] {
        [.stopAll, .releasePromptAudioSession]
    }

    private func commandsForFreshTransition(
        _ snapshot: CallLifecycleSnapshot
    ) -> [CallPromptCommand] {
        switch snapshot.phase {
        case .ringing where snapshot.direction == .incoming:
            return loopCommands(.incomingRingtone, policy: .incomingRespectingSystemPolicy)
        case .ringing:
            return loopCommands(.outgoingRingback, policy: .appOwnedCallPrompt)
        case .busy:
            return oneShotCommands(.busy, maximumDuration: 2.5)
        case .connected:
            return oneShotCommands(.connected, maximumDuration: 1.0)
        case .rejected, .cancelled, .timeout, .ended, .failure:
            return oneShotCommands(.ended, maximumDuration: 1.25)
        case .dialing, .reconnecting:
            return cleanupCommands
        }
    }

    private func restartWaitingLoopIfNeeded(
        _ snapshot: CallLifecycleSnapshot?
    ) -> [CallPromptCommand] {
        guard let snapshot, snapshot.ownsActiveCall, snapshot.phase == .ringing else {
            return cleanupCommands
        }
        if snapshot.direction == .incoming {
            return loopCommands(.incomingRingtone, policy: .incomingRespectingSystemPolicy)
        }
        return loopCommands(.outgoingRingback, policy: .appOwnedCallPrompt)
    }

    private func loopCommands(
        _ prompt: CallPromptKind,
        policy: CallPromptAudioPolicy
    ) -> [CallPromptCommand] {
        [.stopAll, .prepare(policy), .startLoop(prompt)]
    }

    private func oneShotCommands(
        _ prompt: CallPromptKind,
        maximumDuration: TimeInterval
    ) -> [CallPromptCommand] {
        [
            .stopAll,
            .prepare(.appOwnedCallPrompt),
            .playOneShot(prompt, maximumDuration: maximumDuration)
        ]
    }
}

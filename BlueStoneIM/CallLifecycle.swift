import Foundation

/// The signaling direction is independent of the media implementation. Voice and video calls
/// deliberately use the same lifecycle semantics.
enum CallLifecycleDirection: String, Sendable, Equatable {
    case incoming
    case outgoing
}

struct RTCAuthoritativePeerDevice: Sendable, Equatable {
    let uid: String
    let deviceID: String
    let deviceType: String
    let source: String
}

struct RTCResolvedPeerParticipant: Sendable, Equatable {
    let direction: CallLifecycleDirection
    let participant: RemoteRTCRoomParticipant
    let source: String
}

/// Resolves the opposite RTC participant from authoritative call direction and device lineage.
/// A winning device, when present, is a strict fence: another device belonging to the same UID
/// can never be selected merely because it appeared first in a room participant list.
enum RTCDirectionAwarePeerResolver {
    static func direction(
        call: RemoteRTCCall,
        selfUIDs: Set<String>,
        hint: CallLifecycleDirection? = nil
    ) -> CallLifecycleDirection? {
        let normalizedSelfUIDs = Set(selfUIDs.compactMap(normalizedNonempty))
        let callerUID = normalizedNonempty(call.callerUID)
        let calleeUID = normalizedNonempty(call.calleeUID)
        let roleDirection: CallLifecycleDirection?
        if let callerUID,
           normalizedSelfUIDs.contains(callerUID),
           calleeUID.map({ !normalizedSelfUIDs.contains($0) }) ?? true {
            roleDirection = .outgoing
        } else if let calleeUID,
                  normalizedSelfUIDs.contains(calleeUID),
                  callerUID.map({ !normalizedSelfUIDs.contains($0) }) ?? true {
            roleDirection = .incoming
        } else {
            roleDirection = nil
        }
        if let roleDirection, let hint, roleDirection != hint {
            return nil
        }
        return roleDirection ?? hint
    }

    static func authoritativePeerDevice(
        call: RemoteRTCCall,
        direction: CallLifecycleDirection,
        selfUIDs: Set<String>,
        selfDeviceID: String
    ) -> RTCAuthoritativePeerDevice? {
        let devices: [(RemoteRTCDevice?, String)]
        switch direction {
        case .outgoing:
            // accepted_device is the callee winner. callee_device is accepted-call lineage used
            // by older projections and is only considered when accepted_device is absent.
            devices = [(call.acceptedDevice, "accepted_device"), (call.calleeDevice, "callee_device")]
        case .incoming:
            // accepted_device/callee_device identify this callee and must never become the peer.
            devices = [(call.callerDevice, "caller_device")]
        }
        let normalizedSelfUIDs = Set(selfUIDs.compactMap(normalizedNonempty))
        let normalizedSelfDeviceID = normalizedNonempty(selfDeviceID)
        for (device, source) in devices {
            guard let device,
                  let deviceID = normalizedNonempty(device.deviceID),
                  deviceID != normalizedSelfDeviceID else { continue }
            let uid = normalizedNonempty(device.uid) ?? ""
            guard uid.isEmpty || !normalizedSelfUIDs.contains(uid) else { continue }
            return RTCAuthoritativePeerDevice(
                uid: uid,
                deviceID: deviceID,
                deviceType: device.deviceType,
                source: source
            )
        }
        return nil
    }

    static func resolve(
        call: RemoteRTCCall,
        selfUIDs: Set<String>,
        selfParticipant: RemoteRTCRoomParticipant?,
        explicitPeer: RemoteRTCRoomParticipant?,
        participants: [RemoteRTCRoomParticipant],
        directionHint: CallLifecycleDirection? = nil
    ) -> RTCResolvedPeerParticipant? {
        guard let direction = direction(call: call, selfUIDs: selfUIDs, hint: directionHint) else {
            return nil
        }
        let normalizedSelfUIDs = Set(selfUIDs.compactMap(normalizedNonempty))
        let selfDeviceID = normalizedNonempty(selfParticipant?.deviceID ?? "") ?? ""
        let expectedPeerUID = normalizedNonempty(
            direction == .outgoing ? call.calleeUID : call.callerUID
        )
        let authority = authoritativePeerDevice(
            call: call,
            direction: direction,
            selfUIDs: normalizedSelfUIDs,
            selfDeviceID: selfDeviceID
        )

        var candidates: [(RemoteRTCRoomParticipant, String)] = []
        if let explicitPeer {
            candidates.append((explicitPeer, "peer_participant"))
        }
        candidates.append(contentsOf: participants.map { ($0, "participants") })
        var seen = Set<String>()
        candidates = candidates.filter { participant, _ in
            guard let deviceID = normalizedNonempty(participant.deviceID),
                  deviceID != selfDeviceID else { return false }
            let uid = normalizedNonempty(participant.uid) ?? ""
            guard uid.isEmpty || !normalizedSelfUIDs.contains(uid) else { return false }
            guard expectedPeerUID == nil || uid == expectedPeerUID else { return false }
            let key = "\(uid)\u{0}\(deviceID)"
            return seen.insert(key).inserted
        }

        if let authority {
            guard let match = candidates.first(where: { participant, _ in
                normalizedNonempty(participant.deviceID) == authority.deviceID
                    && (authority.uid.isEmpty || normalizedNonempty(participant.uid) == authority.uid)
            }) else {
                return nil
            }
            return RTCResolvedPeerParticipant(
                direction: direction,
                participant: match.0,
                source: authority.source
            )
        }

        if let explicitPeer,
           let explicit = candidates.first(where: {
               $0.1 == "peer_participant"
                   && normalizedNonempty($0.0.deviceID) == normalizedNonempty(explicitPeer.deviceID)
           }) {
            return RTCResolvedPeerParticipant(
                direction: direction,
                participant: explicit.0,
                source: explicit.1
            )
        }
        guard candidates.count == 1, let only = candidates.first else {
            return nil
        }
        return RTCResolvedPeerParticipant(
            direction: direction,
            participant: only.0,
            source: only.1
        )
    }

    private static func normalizedNonempty(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// The complete user-visible call lifecycle. Terminal phases never retain active-call ownership.
enum CallLifecyclePhase: String, CaseIterable, Sendable, Equatable {
    case dialing
    case ringing
    case busy
    case connected
    case rejected
    case cancelled
    case timeout
    case ended
    case reconnecting
    case failure

    var isTerminal: Bool {
        switch self {
        case .busy, .rejected, .cancelled, .timeout, .ended, .failure:
            return true
        case .dialing, .ringing, .connected, .reconnecting:
            return false
        }
    }
}

/// `epoch` is minted by the call owner whenever it claims a new local session. It fences delayed
/// permission, signaling, media, and teardown callbacks even when a server call ID is reused.
struct CallLifecycleSessionIdentity: Hashable, Sendable {
    let scopeID: String
    let callID: String
    let epoch: UInt64

    init(scopeID: String = "default", callID: String, epoch: UInt64) {
        self.scopeID = scopeID
        self.callID = callID
        self.epoch = epoch
    }
}

struct CallLifecycleSnapshot: Sendable, Equatable {
    let identity: CallLifecycleSessionIdentity
    let direction: CallLifecycleDirection
    let phase: CallLifecyclePhase
    /// Last accepted server `state_version`. Local media transitions never advance this clock.
    let revision: Int64
    /// Local mutation fence used only to discard reconciliation responses that started before a
    /// newer local phase change. It is deliberately independent from server `state_version`.
    let localVersion: UInt64
    let hasEverConnected: Bool
    let reason: String

    var ownsActiveCall: Bool {
        !phase.isTerminal
    }
}

struct CallLifecycleEvent: Sendable, Equatable {
    let identity: CallLifecycleSessionIdentity
    let phase: CallLifecyclePhase
    /// Non-nil only for an authoritative server event. Local media/CallKit events use nil.
    let revision: Int64?
    let reason: String

    init(
        identity: CallLifecycleSessionIdentity,
        phase: CallLifecyclePhase,
        revision: Int64? = nil,
        reason: String = ""
    ) {
        self.identity = identity
        self.phase = phase
        self.revision = revision
        self.reason = reason
    }
}

/// A server call projected into an authoritative reconciliation response. `callID` remains a
/// server identity; blank or foreign identities can never terminate the current local owner.
struct CallLifecycleReconciliationItem: Sendable, Equatable {
    let callID: String
    let phase: CallLifecyclePhase
    let revision: Int64
    let reason: String

    init(
        callID: String,
        phase: CallLifecyclePhase,
        revision: Int64,
        reason: String = ""
    ) {
        self.callID = callID
        self.phase = phase
        self.revision = revision
        self.reason = reason
    }
}

/// Owner epoch, server revision, and local version are captured when reconciliation starts. An
/// older response therefore cannot clear a replacement call or a locally advanced call.
struct CallLifecycleReconciliationEvent: Sendable, Equatable {
    let scopeID: String
    let observedOwnerEpoch: UInt64
    let observedOwnerRevision: Int64
    let observedOwnerLocalVersion: UInt64
    let calls: [CallLifecycleReconciliationItem]
    let emptyReason: String

    init(
        scopeID: String,
        observedOwnerEpoch: UInt64,
        observedOwnerRevision: Int64,
        observedOwnerLocalVersion: UInt64,
        calls: [CallLifecycleReconciliationItem],
        emptyReason: String = "authoritative_reconciliation_absent"
    ) {
        self.scopeID = scopeID
        self.observedOwnerEpoch = observedOwnerEpoch
        self.observedOwnerRevision = observedOwnerRevision
        self.observedOwnerLocalVersion = observedOwnerLocalVersion
        self.calls = calls
        self.emptyReason = emptyReason
    }
}

enum CallLifecycleIgnoredReason: Sendable, Equatable {
    case noActiveSession
    case staleEpoch
    case duplicateClaim
    case foreignSession
    case staleRevision
    case invalidTransition
}

enum CallLifecycleTransitionDisposition: Sendable, Equatable {
    case applied
    case ignored(CallLifecycleIgnoredReason)

    var isApplied: Bool {
        self == .applied
    }
}

struct CallLifecycleTransition: Sendable, Equatable {
    let serial: UInt64
    let disposition: CallLifecycleTransitionDisposition
    let previous: CallLifecycleSnapshot?
    let current: CallLifecycleSnapshot?

    /// A newer explicit claim may replace an older local owner. The integration layer must stop
    /// media belonging to this snapshot, but must not treat it as the newly active call.
    let releasedPrevious: CallLifecycleSnapshot?

    var isApplied: Bool {
        disposition.isApplied
    }
}

/// Pure single-call state machine. It never infers ownership from a view, media object, timer, or
/// non-nil legacy session. Only the current session identity owns the active-call slot.
struct CallLifecycleStateMachine: Sendable {
    private(set) var activeSnapshot: CallLifecycleSnapshot?
    private(set) var lastTerminalSnapshot: CallLifecycleSnapshot?
    private(set) var transitionSerial: UInt64 = 0
    private var highestClaimedEpochByScope: [String: UInt64] = [:]

    var hasActiveCall: Bool {
        activeSnapshot?.ownsActiveCall == true
    }

    func ownsActiveCall(_ identity: CallLifecycleSessionIdentity) -> Bool {
        activeSnapshot?.identity == identity && hasActiveCall
    }

    /// Claims authoritative local ownership. A higher epoch is an explicit handoff and releases
    /// any older owner, including one left behind by an interrupted asynchronous start path.
    mutating func claim(
        _ identity: CallLifecycleSessionIdentity,
        direction: CallLifecycleDirection,
        revision: Int64 = 0,
        reason: String = ""
    ) -> CallLifecycleTransition {
        let previous = activeSnapshot
        let highestEpoch = highestClaimedEpochByScope[identity.scopeID]

        if previous?.identity == identity {
            return ignored(.duplicateClaim, previous: previous)
        }
        if let highestEpoch, identity.epoch <= highestEpoch {
            return ignored(.staleEpoch, previous: previous)
        }

        highestClaimedEpochByScope[identity.scopeID] = identity.epoch
        let initialPhase: CallLifecyclePhase = direction == .incoming ? .ringing : .dialing
        let snapshot = CallLifecycleSnapshot(
            identity: identity,
            direction: direction,
            phase: initialPhase,
            revision: revision,
            localVersion: 0,
            hasEverConnected: false,
            reason: reason
        )
        activeSnapshot = snapshot
        transitionSerial &+= 1
        return CallLifecycleTransition(
            serial: transitionSerial,
            disposition: .applied,
            previous: previous,
            current: snapshot,
            releasedPrevious: previous
        )
    }

    /// Applies a monotonic event for the current identity. Duplicate, reordered, foreign-session,
    /// and semantically regressive callbacks are inert and cannot steal or release ownership.
    mutating func apply(_ event: CallLifecycleEvent) -> CallLifecycleTransition {
        guard let previous = activeSnapshot else {
            return ignored(.noActiveSession, previous: nil)
        }
        guard !event.identity.callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ignored(.foreignSession, previous: previous)
        }
        guard event.identity == previous.identity else {
            return ignored(.foreignSession, previous: previous)
        }
        if let serverRevision = event.revision,
           serverRevision <= previous.revision {
            return ignored(.staleRevision, previous: previous)
        }
        guard Self.allowsTransition(
            from: previous.phase,
            to: event.phase,
            direction: previous.direction
        ) else {
            return ignored(.invalidTransition, previous: previous)
        }

        let snapshot = CallLifecycleSnapshot(
            identity: previous.identity,
            direction: previous.direction,
            phase: event.phase,
            revision: event.revision ?? previous.revision,
            localVersion: previous.localVersion &+ 1,
            hasEverConnected: previous.hasEverConnected || event.phase == .connected,
            reason: event.reason
        )
        transitionSerial &+= 1

        if snapshot.phase.isTerminal {
            activeSnapshot = nil
            lastTerminalSnapshot = snapshot
        } else {
            activeSnapshot = snapshot
        }

        return CallLifecycleTransition(
            serial: transitionSerial,
            disposition: .applied,
            previous: previous,
            current: snapshot,
            releasedPrevious: snapshot.phase.isTerminal ? previous : nil
        )
    }

    /// Reduces one authoritative list response against the owner that existed when the request
    /// began. If that exact owner is absent, even when other calls are present, it is released.
    mutating func reconcile(
        _ event: CallLifecycleReconciliationEvent
    ) -> CallLifecycleTransition {
        guard let previous = activeSnapshot else {
            return ignored(.noActiveSession, previous: nil)
        }
        guard event.scopeID == previous.identity.scopeID else {
            return ignored(.foreignSession, previous: previous)
        }
        guard event.observedOwnerEpoch == previous.identity.epoch else {
            return ignored(.staleEpoch, previous: previous)
        }
        guard event.observedOwnerRevision == previous.revision else {
            return ignored(.staleRevision, previous: previous)
        }
        guard event.observedOwnerLocalVersion == previous.localVersion else {
            return ignored(.staleRevision, previous: previous)
        }

        guard let currentCall = event.calls.first(where: {
            !$0.callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.callID == previous.identity.callID
        }) else {
            // The list is authoritative for this scope. Other calls do not keep an owner alive
            // when the call captured at request start is absent.
            return releaseActive(as: .ended, reason: event.emptyReason)
        }

        return apply(
            CallLifecycleEvent(
                identity: previous.identity,
                phase: currentCall.phase,
                revision: currentCall.revision,
                reason: currentCall.reason
            )
        )
    }

    /// Deterministically releases the current owner during logout, scope replacement, or local
    /// teardown. The default is an ordinary ended call; failures should be explicit.
    mutating func releaseActive(
        as phase: CallLifecyclePhase = .ended,
        reason: String = "local_teardown"
    ) -> CallLifecycleTransition {
        guard let previous = activeSnapshot else {
            return ignored(.noActiveSession, previous: nil)
        }
        guard phase.isTerminal else {
            return ignored(.invalidTransition, previous: previous)
        }
        guard Self.allowsTransition(
            from: previous.phase,
            to: phase,
            direction: previous.direction
        ) else {
            return ignored(.invalidTransition, previous: previous)
        }

        // Local teardown must remain able to release ownership even if a malformed remote source
        // already supplied Int64.max as its revision.
        let snapshot = CallLifecycleSnapshot(
            identity: previous.identity,
            direction: previous.direction,
            phase: phase,
            revision: previous.revision,
            localVersion: previous.localVersion &+ 1,
            hasEverConnected: previous.hasEverConnected,
            reason: reason
        )
        transitionSerial &+= 1
        activeSnapshot = nil
        lastTerminalSnapshot = snapshot
        return CallLifecycleTransition(
            serial: transitionSerial,
            disposition: .applied,
            previous: previous,
            current: snapshot,
            releasedPrevious: previous
        )
    }

    private func ignored(
        _ reason: CallLifecycleIgnoredReason,
        previous: CallLifecycleSnapshot?
    ) -> CallLifecycleTransition {
        CallLifecycleTransition(
            serial: transitionSerial,
            disposition: .ignored(reason),
            previous: previous,
            current: previous,
            releasedPrevious: nil
        )
    }

    private static func allowsTransition(
        from previous: CallLifecyclePhase,
        to next: CallLifecyclePhase,
        direction: CallLifecycleDirection
    ) -> Bool {
        guard previous != next, !previous.isTerminal else {
            return false
        }

        switch next {
        case .dialing:
            // For an incoming call this means "answered; media is establishing". It stops the
            // ringtone without falsely declaring the call connected.
            return direction == .incoming && previous == .ringing
        case .ringing:
            return direction == .outgoing && previous == .dialing
        case .connected:
            return previous == .dialing || previous == .ringing || previous == .reconnecting
        case .reconnecting:
            return previous == .connected
        case .busy, .rejected, .cancelled, .timeout:
            return previous == .dialing || previous == .ringing
        case .ended, .failure:
            return true
        }
    }
}

enum CallPromptKind: String, Sendable, Equatable {
    case outgoingRingback
    case incomingRingtone
    case busy
    case connected
    case ended
}

/// Incoming ringtone playback must delegate audibility to CallKit/system silent, focus, and DND
/// policy. The app-owned policy must never be used to bypass those settings.
enum CallPromptAudioPolicy: Sendable, Equatable {
    case appOwnedCallPrompt
    case incomingRespectingSystemPolicy
}

/// Commands are intentionally asset-agnostic. An adapter may use licensed/generated tones or
/// system facilities, but the lifecycle core neither embeds nor synthesizes copyrighted audio.
enum CallPromptCommand: Sendable, Equatable {
    case stopAll
    case prepare(CallPromptAudioPolicy)
    case startLoop(CallPromptKind)
    case playOneShot(CallPromptKind, maximumDuration: TimeInterval)
    case releasePromptAudioSession
}

enum CallPromptEnvironmentEvent: Sendable, Equatable {
    case applicationDidEnterBackground
    case applicationDidBecomeActive
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case audioRouteChanged(CallPromptRouteChangeReason)
    case mediaServicesReset
    case callKitAudioSessionActivated
    case callKitAudioSessionDeactivated
    case applicationWillTerminate
}

/// A small platform-neutral projection of `AVAudioSession.RouteChangeReason`. Keeping the reason
/// lets the adapter honor headphone-disconnect privacy instead of blindly moving a waiting loop
/// onto the speaker.
enum CallPromptRouteChangeReason: Sendable, Equatable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case reconfiguration
}

protocol CallPromptCommandRendering: AnyObject {
    func render(_ commands: [CallPromptCommand])
}

/// Turns accepted lifecycle transitions into deterministic prompt-audio commands. One-shots are
/// never reconstructed by environment reconciliation, so route changes and foregrounding cannot
/// replay connected or ended sounds.
struct CallPromptCoordinator: Sendable {
    private(set) var lastRenderedTransitionSerial: UInt64 = 0
    private(set) var isSuppressed = false
    private(set) var isTerminated = false

    mutating func commands(for transition: CallLifecycleTransition) -> [CallPromptCommand] {
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
    mutating func commands(
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

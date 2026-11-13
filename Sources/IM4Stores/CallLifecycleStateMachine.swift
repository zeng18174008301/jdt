// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Foundation
import IM4Domain

public struct CallLifecycleStateMachine: Sendable {
    public init() {}
    public private(set) var activeSnapshot: CallLifecycleSnapshot?
    public private(set) var lastTerminalSnapshot: CallLifecycleSnapshot?
    public private(set) var transitionSerial: UInt64 = 0
    private var highestClaimedEpochByScope: [String: UInt64] = [:]

    public var hasActiveCall: Bool {
        activeSnapshot?.ownsActiveCall == true
    }

    public func ownsActiveCall(_ identity: CallLifecycleSessionIdentity) -> Bool {
        activeSnapshot?.identity == identity && hasActiveCall
    }

    /// Claims authoritative local ownership. A higher epoch is an explicit handoff and releases
    /// any older owner, including one left behind by an interrupted asynchronous start path.
    public mutating func claim(
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
    public mutating func apply(_ event: CallLifecycleEvent) -> CallLifecycleTransition {
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
    public mutating func reconcile(
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
    public mutating func releaseActive(
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

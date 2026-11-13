// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Foundation

public enum CallLifecycleDirection: String, Sendable, Equatable {
    case incoming
    case outgoing
}

public enum CallLifecyclePhase: String, CaseIterable, Sendable, Equatable {
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

    public var isTerminal: Bool {
        switch self {
        case .busy, .rejected, .cancelled, .timeout, .ended, .failure:
            return true
        case .dialing, .ringing, .connected, .reconnecting:
            return false
        }
    }
}

public struct CallLifecycleSessionIdentity: Hashable, Sendable {
    public let scopeID: String
    public let callID: String
    public let epoch: UInt64

    public init(scopeID: String = "default", callID: String, epoch: UInt64) {
        self.scopeID = scopeID
        self.callID = callID
        self.epoch = epoch
    }
}

public struct CallLifecycleSnapshot: Sendable, Equatable {
    public let identity: CallLifecycleSessionIdentity
    public let direction: CallLifecycleDirection
    public let phase: CallLifecyclePhase
    /// Last accepted server `state_version`. Local media transitions never advance this clock.
    public let revision: Int64
    /// Local mutation fence used only to discard reconciliation responses that started before a
    /// newer local phase change. It is deliberately independent from server `state_version`.
    public let localVersion: UInt64
    public let hasEverConnected: Bool
    public let reason: String

    public var ownsActiveCall: Bool {
        !phase.isTerminal
    }

    public init(
        identity: CallLifecycleSessionIdentity,
        direction: CallLifecycleDirection,
        phase: CallLifecyclePhase,
        revision: Int64,
        localVersion: UInt64,
        hasEverConnected: Bool,
        reason: String
    ) {
        self.identity = identity
        self.direction = direction
        self.phase = phase
        self.revision = revision
        self.localVersion = localVersion
        self.hasEverConnected = hasEverConnected
        self.reason = reason
    }
}

public struct CallLifecycleEvent: Sendable, Equatable {
    public let identity: CallLifecycleSessionIdentity
    public let phase: CallLifecyclePhase
    /// Non-nil only for an authoritative server event. Local media/CallKit events use nil.
    public let revision: Int64?
    public let reason: String

    public init(
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

public struct CallLifecycleReconciliationItem: Sendable, Equatable {
    public let callID: String
    public let phase: CallLifecyclePhase
    public let revision: Int64
    public let reason: String

    public init(
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

public struct CallLifecycleReconciliationEvent: Sendable, Equatable {
    public let scopeID: String
    public let observedOwnerEpoch: UInt64
    public let observedOwnerRevision: Int64
    public let observedOwnerLocalVersion: UInt64
    public let calls: [CallLifecycleReconciliationItem]
    public let emptyReason: String

    public init(
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

public enum CallLifecycleIgnoredReason: Sendable, Equatable {
    case noActiveSession
    case staleEpoch
    case duplicateClaim
    case foreignSession
    case staleRevision
    case invalidTransition
}

public enum CallLifecycleTransitionDisposition: Sendable, Equatable {
    case applied
    case ignored(CallLifecycleIgnoredReason)

    public var isApplied: Bool {
        self == .applied
    }
}

public struct CallLifecycleTransition: Sendable, Equatable {
    public let serial: UInt64
    public let disposition: CallLifecycleTransitionDisposition
    public let previous: CallLifecycleSnapshot?
    public let current: CallLifecycleSnapshot?

    /// A newer explicit claim may replace an older local owner. The integration layer must stop
    /// media belonging to this snapshot, but must not treat it as the newly active call.
    public let releasedPrevious: CallLifecycleSnapshot?

    public var isApplied: Bool {
        disposition.isApplied
    }

    public init(
        serial: UInt64,
        disposition: CallLifecycleTransitionDisposition,
        previous: CallLifecycleSnapshot?,
        current: CallLifecycleSnapshot?,
        releasedPrevious: CallLifecycleSnapshot?
    ) {
        self.serial = serial
        self.disposition = disposition
        self.previous = previous
        self.current = current
        self.releasedPrevious = releasedPrevious
    }
}

public enum CallPromptKind: String, Sendable, Equatable {
    case outgoingRingback
    case incomingRingtone
    case busy
    case connected
    case ended
}

public enum CallPromptAudioPolicy: Sendable, Equatable {
    case appOwnedCallPrompt
    case incomingRespectingSystemPolicy
}

public enum CallPromptCommand: Sendable, Equatable {
    case stopAll
    case prepare(CallPromptAudioPolicy)
    case startLoop(CallPromptKind)
    case playOneShot(CallPromptKind, maximumDuration: TimeInterval)
    case releasePromptAudioSession
}

public enum CallPromptEnvironmentEvent: Sendable, Equatable {
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

public enum CallPromptRouteChangeReason: Sendable, Equatable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case reconfiguration
}

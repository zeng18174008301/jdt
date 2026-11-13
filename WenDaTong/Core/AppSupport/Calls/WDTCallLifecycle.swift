import Foundation
import IM4Domain
import IM4Stores // WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111

/// The signaling direction is independent of the media implementation. Voice and video calls
/// deliberately use the same lifecycle semantics.
typealias CallLifecycleDirection = IM4Domain.CallLifecycleDirection

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
typealias CallLifecyclePhase = IM4Domain.CallLifecyclePhase

/// `epoch` is minted by the call owner whenever it claims a new local session. It fences delayed
/// permission, signaling, media, and teardown callbacks even when a server call ID is reused.
typealias CallLifecycleSessionIdentity = IM4Domain.CallLifecycleSessionIdentity

typealias CallLifecycleSnapshot = IM4Domain.CallLifecycleSnapshot

typealias CallLifecycleEvent = IM4Domain.CallLifecycleEvent

/// A server call projected into an authoritative reconciliation response. `callID` remains a
/// server identity; blank or foreign identities can never terminate the current local owner.
typealias CallLifecycleReconciliationItem = IM4Domain.CallLifecycleReconciliationItem

/// Owner epoch, server revision, and local version are captured when reconciliation starts. An
/// older response therefore cannot clear a replacement call or a locally advanced call.
typealias CallLifecycleReconciliationEvent = IM4Domain.CallLifecycleReconciliationEvent

typealias CallLifecycleIgnoredReason = IM4Domain.CallLifecycleIgnoredReason

typealias CallLifecycleTransitionDisposition = IM4Domain.CallLifecycleTransitionDisposition

typealias CallLifecycleTransition = IM4Domain.CallLifecycleTransition

/// Pure single-call state machine. It never infers ownership from a view, media object, timer, or
/// non-nil legacy session. Only the current session identity owns the active-call slot.
typealias CallLifecycleStateMachine = IM4Stores.CallLifecycleStateMachine

typealias CallPromptKind = IM4Domain.CallPromptKind

/// Incoming ringtone playback must delegate audibility to CallKit/system silent, focus, and DND
/// policy. The app-owned policy must never be used to bypass those settings.
typealias CallPromptAudioPolicy = IM4Domain.CallPromptAudioPolicy

/// Commands are intentionally asset-agnostic. An adapter may use licensed/generated tones or
/// system facilities, but the lifecycle core neither embeds nor synthesizes copyrighted audio.
typealias CallPromptCommand = IM4Domain.CallPromptCommand

typealias CallPromptEnvironmentEvent = IM4Domain.CallPromptEnvironmentEvent

/// A small platform-neutral projection of `AVAudioSession.RouteChangeReason`. Keeping the reason
/// lets the adapter honor headphone-disconnect privacy instead of blindly moving a waiting loop
/// onto the speaker.
typealias CallPromptRouteChangeReason = IM4Domain.CallPromptRouteChangeReason

protocol CallPromptCommandRendering: AnyObject {
    func render(_ commands: [CallPromptCommand])
}

/// Turns accepted lifecycle transitions into deterministic prompt-audio commands. One-shots are
/// never reconstructed by environment reconciliation, so route changes and foregrounding cannot
/// replay connected or ended sounds.
typealias CallPromptCoordinator = IM4Stores.CallPromptCoordinator

import SwiftUI
import UIKit
import IM4Domain
import IM4Stores
import IM4Features

// WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112_BEGIN
@MainActor
final class RTCCallIdleTimerCoordinator {
    static let shared = RTCCallIdleTimerCoordinator()

    private var keepsScreenAwake = false

    func update(activeCallID: String?) {
        let shouldKeepAwake = activeCallID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard keepsScreenAwake != shouldKeepAwake ||
              UIApplication.shared.isIdleTimerDisabled != shouldKeepAwake else { return }
        keepsScreenAwake = shouldKeepAwake
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }

    func reset() {
        update(activeCallID: nil)
    }
}

// WDT_IOS1_SPLIT_MOUNTED_ROOT_SOURCE_20261112_END

struct IncomingCallScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var callStore: CallStore
    let call: IncomingVoiceCall
    private var caller: IMUser { state.displayUserForVoiceCall(call.caller) }
    private var matchesCurrentCall: Bool {
        guard let current = callStore.incomingVoiceCall else { return false }
        return current.id == call.id && current.callID == call.callID && current.isVideo == call.isVideo
    }
    var body: some View {
        IncomingCallScreenContent(input: .init(callerName: caller.displayName,
            enterprise: caller.enterprise, department: caller.department, title: caller.title,
            isVideo: call.isVideo, answerMode: callStore.incomingCallAnswerMode), avatar: {
                AvatarView(name: caller.displayName, seed: caller.avatarSeed, size: 112,
                    imageURL: caller.displayAvatarURL, avatarVersion: caller.avatarVersion,
                    avatarUpdatedAt: caller.avatarUpdatedAt,
                    certificationReference: state.certificationPillSource.reference(forExactUID: caller.id))
            }, certification: {
                CertificationPillView(exactUID: caller.id, compact: false)
            }, toast: {
                state.toastPresentationStore.observe { toast in IncomingCallToastMessage(message: toast) }
            }, onDecline: {
                guard matchesCurrentCall else { return }; state.declineIncomingVoiceCall()
            }, onAnswer: {
                guard matchesCurrentCall else { return }
                if call.isVideo { state.acceptIncomingVideoCall(as: "video") }
                else { state.acceptIncomingVoiceCall() }
            }, onAnswerAudio: {
                guard matchesCurrentCall else { return }; state.acceptIncomingVideoCall(as: "audio")
            })
    }
}

struct RTCIncomingCallCard: View {
    @EnvironmentObject private var state: AppState
    let call: IncomingVoiceCall
    private var caller: IMUser { state.displayUserForVoiceCall(call.caller) }
    var body: some View {
        RTCIncomingCallCardContent(callerName: caller.displayName, isVideo: call.isVideo, avatar: {
            AvatarView(name: caller.displayName, seed: caller.avatarSeed, size: 54,
                imageURL: caller.displayAvatarURL, avatarVersion: caller.avatarVersion,
                avatarUpdatedAt: caller.avatarUpdatedAt,
                certificationReference: state.certificationPillSource.reference(forExactUID: caller.id))
        }, certification: { CertificationPillView(exactUID: caller.id, compact: true) },
        onDecline: { state.declineIncomingVoiceCall() }, onAnswer: {
            if call.isVideo { state.acceptIncomingVideoCall(as: "video") }
            else { state.acceptIncomingVoiceCall() }
        })
    }
}

struct VoiceCallScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var callStore: CallStore
    let session: VoiceCallSession
    private var currentSession: VoiceCallSession { callStore.activeVoiceCall ?? session }
    var body: some View {
        let call = currentSession
        let peer = state.displayUserForVoiceCall(call.peer)
        VoiceCallScreenContent(input: .init(peerName: peer.displayName, statusText: call.statusText,
            direction: call.direction, connectedAt: call.connectedAt,
            speakerOn: call.speakerOn, isMuted: call.isMuted), avatar: {
                AvatarView(name: peer.displayName, seed: peer.avatarSeed, size: 104,
                    imageURL: peer.displayAvatarURL, avatarVersion: peer.avatarVersion,
                    avatarUpdatedAt: peer.avatarUpdatedAt,
                    certificationReference: state.certificationPillSource.reference(forExactUID: peer.id))
            }, certification: { CertificationPillView(exactUID: peer.id, compact: false) },
            onToggleMuted: { state.toggleActiveCallMuted() },
            onToggleSpeaker: { state.toggleActiveCallSpeaker() }, onEnd: { state.endActiveVoiceCall() })
    }
}

import SwiftUI
import IM4Domain
import IM4Stores
import IM4Features

struct VideoCallPreviewScreen: View {
    @EnvironmentObject private var state: AppState
    let preview: VideoCallPreview
    var body: some View {
        VideoCallPreviewContent(input: .init(peerName: preview.peer.name,
            cameraEnabled: preview.cameraEnabled, isPreparing: preview.isPreparing,
            isStartingCall: preview.isStartingCall, unavailableReason: preview.unavailableReason,
            startError: preview.startError), localRenderer: {
                RTCVideoRendererView(local: true, mirrored: true)
            }, certification: { CertificationPillView(exactUID: preview.peer.id, compact: true) },
            onCancel: { state.dismissVideoCallPreview() },
            onToggleCamera: { state.setVideoPreviewCameraEnabled(!preview.cameraEnabled) },
            onStart: { state.startOutgoingVideoCallFromPreview() })
    }
}

struct VideoCallScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var callStore: CallStore
    let session: VoiceCallSession
    var screenshotRemoteFrame = false
    private var current: VoiceCallSession { callStore.activeVoiceCall ?? session }
    var body: some View {
        VideoCallScreenContent(input: .init(sessionID: current.id, peerName: current.peer.name,
            statusText: current.statusText, connectedAt: current.connectedAt, mediaMode: current.mediaMode,
            remoteCameraEnabled: current.remoteCameraEnabled, remoteVideoTrackReady: current.remoteVideoTrackReady,
            localCameraEnabled: current.localCameraEnabled, frontCamera: current.cameraPosition == .front,
            speakerOn: current.speakerOn, isMuted: current.isMuted,
            isRecoveringNetwork: current.isRecoveringNetwork,
            endError: callStore.activeCallEndError, isEnding: callStore.isEndingActiveCall), remoteRenderer: { changed in
                #if DEBUG
                if screenshotRemoteFrame { VideoCallSyntheticRemoteFrame() }
                else { RTCVideoRendererView(local: false, onVideoSizeChanged: changed) }
                #else
                RTCVideoRendererView(local: false, onVideoSizeChanged: changed)
                #endif
            }, localRenderer: { mirrored in RTCVideoRendererView(local: true, mirrored: mirrored) },
            certification: { CertificationPillView(exactUID: current.peer.id, compact: false) },
            onMinimize: { state.setActiveVideoCallMinimized(true) },
            onToggleSpeaker: { state.toggleActiveCallSpeaker() },
            onDowngradeAudio: { state.downgradeActiveVideoCallToAudio() },
            onSwitchCamera: { state.switchActiveVideoCamera() },
            onToggleMuted: { state.toggleActiveCallMuted() },
            onToggleCamera: { state.toggleActiveVideoCamera() }, onEnd: { state.endActiveVoiceCall() })
        .onAppear { VideoCallOrientationPolicy.isVideoCallPresented = true }
        .onDisappear { VideoCallOrientationPolicy.isVideoCallPresented = false }
    }
}

struct MinimizedVideoCallBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var callStore: CallStore
    let session: VoiceCallSession
    var body: some View {
        MinimizedVideoCallBarContent(input: .init(peerName: session.peer.name, connectedAt: session.connectedAt,
            statusText: session.statusText, isMuted: session.isMuted, localCameraEnabled: session.localCameraEnabled,
            isRecoveringNetwork: session.isRecoveringNetwork, isEnding: callStore.isEndingActiveCall),
            certification: { CertificationPillView(exactUID: session.peer.id, compact: true) },
            onRestore: { state.setActiveVideoCallMinimized(false) }, onEnd: { state.endActiveVoiceCall() })
    }
}

struct VideoCallTerminalResultScreen: View {
    @EnvironmentObject private var state: AppState
    let result: VideoCallTerminalResult
    var body: some View {
        VideoCallTerminalResultContent(input: .init(title: result.title, cause: result.cause,
            durationText: result.durationText, nextAction: result.nextAction), avatar: {
                AvatarView(name: result.peer.displayName, seed: result.peer.avatarSeed, size: 88,
                    imageURL: result.peer.displayAvatarURL, avatarVersion: result.peer.avatarVersion,
                    avatarUpdatedAt: result.peer.avatarUpdatedAt,
                    certificationReference: state.certificationPillSource.reference(forExactUID: result.peer.id))
            }, onClose: { state.dismissVideoCallTerminalResult() })
    }
}

#if DEBUG
private struct VideoCallSyntheticRemoteFrame: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.28, blue: 0.48), Color(red: 0.04, green: 0.08, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 16) {
                Circle()
                    .fill(Color(red: 0.98, green: 0.78, blue: 0.65))
                    .frame(width: 112, height: 112)
                RoundedRectangle(cornerRadius: 54)
                    .fill(Color(red: 0.32, green: 0.54, blue: 0.78))
                    .frame(width: 230, height: 180)
                Text("UAT 远端画面")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("测试用远端视频画面")
        }
    }
}
#endif

// WDT_IOS1_FEATURES_CALLS_UI_20261111_BEGIN
typealias VideoCallDurationFormatter = IM4Features.VideoCallDurationFormatter
// WDT_IOS1_FEATURES_CALLS_UI_20261111_END

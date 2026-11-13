import Foundation
import SwiftUI
import IM4DesignSystem

public struct VideoCallScreenInput: Sendable {
    let sessionID: String
    let peerName: String
    let statusText: String
    let connectedAt: Date?
    let mediaMode: String
    let remoteCameraEnabled: Bool
    let remoteVideoTrackReady: Bool
    let localCameraEnabled: Bool
    let frontCamera: Bool
    let speakerOn: Bool
    let isMuted: Bool
    let isRecoveringNetwork: Bool
    let endError: String?
    let isEnding: Bool
    public init(sessionID: String, peerName: String, statusText: String, connectedAt: Date?, mediaMode: String, remoteCameraEnabled: Bool, remoteVideoTrackReady: Bool, localCameraEnabled: Bool, frontCamera: Bool, speakerOn: Bool, isMuted: Bool, isRecoveringNetwork: Bool, endError: String?, isEnding: Bool) {
        self.sessionID = sessionID
        self.peerName = peerName
        self.statusText = statusText
        self.connectedAt = connectedAt
        self.mediaMode = mediaMode
        self.remoteCameraEnabled = remoteCameraEnabled
        self.remoteVideoTrackReady = remoteVideoTrackReady
        self.localCameraEnabled = localCameraEnabled
        self.frontCamera = frontCamera
        self.speakerOn = speakerOn
        self.isMuted = isMuted
        self.isRecoveringNetwork = isRecoveringNetwork
        self.endError = endError
        self.isEnding = isEnding
    }
}

struct VideoCallStageLayout {
    let videoSize: CGSize
    let controlsFrame: CGRect

    init(available: CGSize) {
        let width = max(0, available.width)
        let height = max(0, available.height)
        // Keep the same vertical hierarchy through rotation. Neither controls
        // nor the self-preview reserve a column from the remote picture.
        let controlsHeight = min(190, height * 0.42)
        videoSize = CGSize(width: width, height: height - controlsHeight)
        controlsFrame = CGRect(x: 0, y: videoSize.height, width: width, height: controlsHeight)
    }

    static func videoRect(source: CGSize, available: CGSize) -> CGRect {
        let width = max(0, available.width), height = max(0, available.height)
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        let scale = min(width / source.width, height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (width - size.width) / 2, y: (height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

public struct VideoCallScreenContent<Remote: View, Local: View, Certification: View>: View {
    let input: VideoCallScreenInput
    let remoteRenderer: (@escaping (CGSize) -> Void) -> Remote
    let localRenderer: (Bool) -> Local
    let certification: () -> Certification
    let onMinimize: () -> Void
    let onToggleSpeaker: () -> Void
    let onDowngradeAudio: () -> Void
    let onSwitchCamera: () -> Void
    let onToggleMuted: () -> Void
    let onToggleCamera: () -> Void
    let onEnd: () -> Void
    @State private var controlsVisible = true
    @State private var remoteFrameSize = CGSize.zero
    private static var showVideoToAudioSwitchControl: Bool { false }
    private static var showVideoCameraSwitchControl: Bool { false }
    public init(input: VideoCallScreenInput,
                @ViewBuilder remoteRenderer: @escaping (@escaping (CGSize) -> Void) -> Remote,
                @ViewBuilder localRenderer: @escaping (Bool) -> Local,
                @ViewBuilder certification: @escaping () -> Certification,
                onMinimize: @escaping () -> Void, onToggleSpeaker: @escaping () -> Void,
                onDowngradeAudio: @escaping () -> Void, onSwitchCamera: @escaping () -> Void,
                onToggleMuted: @escaping () -> Void, onToggleCamera: @escaping () -> Void,
                onEnd: @escaping () -> Void) {
        self.input = input; self.remoteRenderer = remoteRenderer; self.localRenderer = localRenderer
        self.certification = certification; self.onMinimize = onMinimize
        self.onToggleSpeaker = onToggleSpeaker; self.onDowngradeAudio = onDowngradeAudio
        self.onSwitchCamera = onSwitchCamera; self.onToggleMuted = onToggleMuted
        self.onToggleCamera = onToggleCamera; self.onEnd = onEnd
    }
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        onMinimize()
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 44, height: 44)
                    }
                    Spacer()
                    VStack {
                        Text(input.statusText).font(.headline)
                        if let connectedAt = input.connectedAt {
                            VideoCallDurationText(connectedAt: connectedAt)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    Spacer()
                    Color.clear.frame(width: 44)
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.82))
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
                GeometryReader { proxy in
                    let layout = VideoCallStageLayout(available: proxy.size)
                    ZStack(alignment: .topLeading) {
                        videoStage
                            .frame(width: layout.videoSize.width, height: layout.videoSize.height)
                        ScrollView(showsIndicators: false) {
                            ScrollView(.horizontal, showsIndicators: true) {
                                callControls.frame(width: max(320, layout.controlsFrame.width))
                            }
                        }
                        .frame(width: layout.controlsFrame.width, height: layout.controlsFrame.height)
                        .offset(x: layout.controlsFrame.minX, y: layout.controlsFrame.minY)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)
                    }
                }
            }
        }
        .accessibilityIdentifier("video_call_screen")
        .interactiveDismissDisabled(true)
        .onChange(of: input.sessionID) { _ in
            controlsVisible = true
            remoteFrameSize = .zero
        }
        .onChange(of: input.remoteVideoTrackReady) { ready in
            if !ready { remoteFrameSize = .zero }
        }
        .accessibilityAction(.escape) { controlsVisible = true }
    }

    private var videoStage: some View {
        GeometryReader { proxy in
            let region = VideoCallStageLayout.videoRect(source: remoteFrameSize, available: proxy.size)
            ZStack(alignment: .topLeading) {
                remoteVideo
                    .id(input.sessionID)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { controlsVisible.toggle() }
                    .accessibilityAction(named: controlsVisible ? "隐藏通话控制" : "显示通话控制") {
                        controlsVisible.toggle()
                    }
                if input.mediaMode == "video", input.localCameraEnabled {
                    SafeAreaDraggableLocalVideo(
                        mirrored: input.frontCamera,
                        videoRegion: region, renderer: localRenderer
                    )
                    .id(input.sessionID)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteVideo: some View {
        if input.mediaMode == "video",
           input.remoteCameraEnabled,
           input.remoteVideoTrackReady {
            remoteRenderer(updateRemoteFrameSize)
        } else {
            VStack(spacing: 14) {
                Image(systemName: input.mediaMode == "video" ? "video.fill" : "phone.fill")
                    .font(.system(size: 52))
                HStack(spacing: 7) {
                    Text(input.peerName)
                        .font(.title.bold())
                        .lineLimit(1)
                    certification()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("video_call_peer_profile_disabled")
                .accessibilityHint("通话期间不能打开用户资料")
                .accessibilityAddTraits(.isStaticText)
                Text(remotePlaceholderText)
            }
            .foregroundStyle(.white)
        }
    }

    private func updateRemoteFrameSize(_ size: CGSize) {
        guard size != remoteFrameSize else { return }
        remoteFrameSize = size
    }

    private var callControls: some View {
        VStack(spacing: 8) {
            if input.isRecoveringNetwork {
                Text("网络较弱，正在自动恢复连接")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.orange.opacity(0.94), in: Capsule())
            }
            controls
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var remotePlaceholderText: String {
        if input.mediaMode != "video" { return "语音通话" }
        if !input.remoteCameraEnabled { return "对方已关闭摄像头" }
        return "等待对方画面"
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let error = input.endError {
                Text(error)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(Color.red.opacity(0.94), in: Capsule())
                    .accessibilityIdentifier("video_call_end_error")
            }
            // JHT_MOD_BEGIN RTC_VIDEO_REMOVE_AUDIO_SWITCH_BUTTON_20260912 - 修改开始：视频通话页移除媒体切换入口，只保留基础通话控制
            HStack(spacing: 12) {
                Button { onToggleSpeaker() } label: {
                    Label(input.speakerOn ? "扬声器" : "听筒", systemImage: "speaker.wave.3.fill")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("声音输出")
                .accessibilityValue(input.speakerOn ? "扬声器" : "听筒")
                .accessibilityIdentifier("video_call_speaker_button")
                // JHT_MOD_BEGIN RTC_VIDEO_HIDE_AUDIO_SWITCH_ENTRY_20260912 - 修改开始：仅隐藏本地 UI 入口，不调用降级语音业务
                if input.mediaMode == "video", Self.showVideoToAudioSwitchControl {
                    Button { onDowngradeAudio() } label: {
                        Label("切换语音", systemImage: "phone.fill")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("video_call_downgrade_audio_button")
                }
                // JHT_MOD_END RTC_VIDEO_HIDE_AUDIO_SWITCH_ENTRY_20260912 - 修改结束
                Spacer(minLength: 0)
                // JHT_MOD_BEGIN RTC_VIDEO_HIDE_CAMERA_SWITCH_BUTTON_20260912 - 修改开始：仅隐藏本地 UI 入口，不删除切换镜头业务
                if input.mediaMode == "video", Self.showVideoCameraSwitchControl {
                    Button { onSwitchCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("切换镜头")
                    .accessibilityIdentifier("video_call_switch_camera_button")
                }
                // JHT_MOD_END RTC_VIDEO_HIDE_CAMERA_SWITCH_BUTTON_20260912 - 修改结束
            }
            // JHT_MOD_END RTC_VIDEO_REMOVE_AUDIO_SWITCH_BUTTON_20260912 - 修改结束
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            HStack(alignment: .top, spacing: 24) {
                VideoRoundButton(title: input.isMuted ? "取消静音" : "静音",
                                 systemImage: input.isMuted ? "mic.slash.fill" : "mic.fill") {
                    onToggleMuted()
                }
                .accessibilityValue(input.isMuted ? "麦克风已静音" : "麦克风已开启")
                .accessibilityIdentifier("video_call_mute_button")
                if input.mediaMode == "video" {
                    VideoRoundButton(title: input.localCameraEnabled ? "关闭摄像头" : "开启摄像头",
                                     systemImage: input.localCameraEnabled ? "video.fill" : "video.slash.fill") {
                        onToggleCamera()
                    }
                    .accessibilityValue(input.localCameraEnabled ? "摄像头已开启" : "摄像头已关闭")
                    .accessibilityIdentifier("video_call_camera_button")
                }
                Button { onEnd() } label: {
                    VStack(spacing: 7) {
                        Image(systemName: input.isEnding ? "hourglass" : "phone.down.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .frame(width: 94, height: 52)
                            .background(Color.red, in: Capsule())
                        Text(input.isEnding ? "正在结束…" : "结束通话")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                .disabled(input.isEnding)
                .accessibilityIdentifier("video_call_end_button")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
    }

}

import SwiftUI

struct VideoCallPreviewControlPresentation: Equatable {
    let cameraTitle: String
    let cameraSystemImage: String
    let cameraControlEnabled: Bool
    let startTitle: String

    static func resolve(
        cameraEnabled: Bool,
        isPreparing: Bool,
        isStartingCall: Bool,
        unavailableReason: String?
    ) -> Self {
        let cameraUnavailable = !(unavailableReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        return Self(
            cameraTitle: cameraUnavailable
                ? "摄像头不可用"
                : (cameraEnabled ? "关闭摄像头" : "开启摄像头"),
            cameraSystemImage: cameraUnavailable || !cameraEnabled
                ? "video.slash.fill"
                : "video.fill",
            cameraControlEnabled: !cameraUnavailable && !isPreparing && !isStartingCall,
            startTitle: isStartingCall
                ? "正在发起…"
                : (cameraUnavailable ? "关闭摄像头继续" : "开始呼叫")
        )
    }
}

enum VideoCallScreenshotScenario: String {
    case preview
    case permissionDenial = "permission-denial"
    case incoming
    case outgoing
    case joining
    case signaling
    case inCall = "in-call"
    case floating
    case downgrade
    case reconnecting
    case background
    case returning
    case remoteCameraOff = "remote-camera-off"
    case remoteCameraOn = "remote-camera-on"
    case terminalLocal = "terminal-local"
    case terminalRemote = "terminal-remote"
    case terminalRejected = "terminal-rejected"
    case terminalBusy = "terminal-busy"
    case terminalTimeout = "terminal-timeout"
    case terminalFailure = "terminal-failure"
    case terminalMissed = "terminal-missed"
    case terminalPermission = "terminal-permission"
    case terminalMedia = "terminal-media"
    case terminalSession = "terminal-session"
    case terminalLicense = "terminal-license"

    static var requested: Self? {
        #if DEBUG
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--video-call-screenshot"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return nil }
        return Self(rawValue: ProcessInfo.processInfo.arguments[index + 1])
        #else
        return nil
        #endif
    }
}

struct VideoCallScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: VideoCallScreenshotScenario

    private var peer: IMUser {
        IMUser(
            id: "video-fixture-peer",
            name: "林晓雨",
            title: "产品设计师",
            department: "产品中心",
            phone: "",
            email: "",
            status: "online",
            enterprise: "问达通",
            avatarSeed: 0x5667D8,
            badges: []
        )
    }

    private var session: VoiceCallSession {
        let isWeakNetworkFixture = scenario == .floating || scenario == .downgrade || scenario == .reconnecting || scenario == .returning
        let statusText: String
        let mediaState: RTCVoiceMediaState
        switch scenario {
        case .outgoing:
            statusText = "正在呼叫"
            mediaState = .connecting
        case .joining:
            statusText = "正在加入通话"
            mediaState = .preparing
        case .signaling:
            statusText = "正在建立安全连接"
            mediaState = .signaling
        case .reconnecting:
            statusText = "网络较弱，正在恢复"
            mediaState = .unstable
        case .background:
            statusText = "摄像头已暂停，语音仍在继续"
            mediaState = .connected
        case .returning:
            statusText = "正在恢复视频连接"
            mediaState = .unstable
        default:
            statusText = isWeakNetworkFixture ? "网络较弱，正在恢复" : "通话中"
            mediaState = .connected
        }
        return VoiceCallSession(
            id: "video-fixture-call",
            callID: "fixture",
            peer: peer,
            direction: "呼出",
            startedAt: "刚刚",
            statusText: statusText,
            mediaState: mediaState,
            isMuted: false,
            speakerOn: true,
            connectedAt: mediaState == .connected || mediaState == .unstable ? Date().addingTimeInterval(-63) : nil,
            requestedMediaMode: "video",
            mediaMode: "video",
            localCameraEnabled: scenario != .background,
            remoteCameraEnabled: scenario != .remoteCameraOff,
            isMinimized: scenario == .floating,
            isRecoveringNetwork: isWeakNetworkFixture,
            remoteVideoTrackReady: scenario == .remoteCameraOn || scenario == .inCall
        )
    }

    private var terminalResult: VideoCallTerminalResult? {
        let reason: String
        switch scenario {
        case .terminalLocal: reason = "local_hangup"
        case .terminalRemote: reason = "remote_hangup"
        case .terminalRejected: reason = "rejected"
        case .terminalBusy: reason = "busy"
        case .terminalTimeout: reason = "timeout"
        case .terminalFailure: reason = "connection_failed"
        case .terminalMissed: reason = "missed"
        case .terminalPermission: reason = "permission_denied"
        case .terminalMedia: reason = "media_failed"
        case .terminalSession: reason = "session_changed"
        case .terminalLicense: reason = "license_revoked"
        default: return nil
        }
        return VideoCallTerminalResult(peer: peer, reason: reason, durationText: "01:03")
    }

    var body: some View {
        ZStack {
            switch scenario {
            case .preview:
                VideoCallPreviewScreen(
                    preview: VideoCallPreview(
                        id: "fixture-preview",
                        peer: peer,
                        channelID: "direct-fixture",
                        cameraEnabled: true,
                        isPreparing: false,
                        unavailableReason: nil
                    )
                )
            case .permissionDenial:
                VideoCallPreviewScreen(
                    preview: VideoCallPreview(
                        id: "fixture-preview-denied",
                        peer: peer,
                        channelID: "direct-fixture",
                        cameraEnabled: false,
                        isPreparing: false,
                        unavailableReason: "未获得摄像头权限，请在系统设置中允许后重试。",
                        startError: "麦克风或摄像头权限未开启。"
                    )
                )
            case .incoming:
                Color(red: 0.94, green: 0.96, blue: 1).ignoresSafeArea()
                IncomingCallScreen(
                    call: IncomingVoiceCall(
                        id: "fixture-incoming",
                        callID: "fixture",
                        caller: peer,
                        startedAt: "刚刚",
                        source: "好友视频通话",
                        requestedMediaMode: "video"
                    )
                )
            case .outgoing, .joining, .signaling, .inCall, .reconnecting, .background, .returning, .remoteCameraOff:
                VideoCallScreen(session: session)
            case .remoteCameraOn:
                VideoCallScreen(session: session, screenshotRemoteFrame: true)
            case .floating:
                Color(red: 0.94, green: 0.96, blue: 1).ignoresSafeArea()
                VStack {
                    MinimizedVideoCallBar(session: session)
                    Spacer()
                    Text("聊天界面可继续使用")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .downgrade:
                // JHT_MOD_BEGIN RTC_VIDEO_REMOVE_AUDIO_SWITCH_BUTTON_20260912 - 修改开始：正式页已移除媒体切换入口，截图场景不再模拟该弹窗
                VideoCallScreen(session: session)
                // JHT_MOD_END RTC_VIDEO_REMOVE_AUDIO_SWITCH_BUTTON_20260912 - 修改结束
            case .terminalLocal, .terminalRemote, .terminalRejected, .terminalBusy,
                 .terminalTimeout, .terminalFailure, .terminalMissed, .terminalPermission,
                 .terminalMedia, .terminalSession, .terminalLicense:
                if let terminalResult {
                    VideoCallTerminalResultScreen(result: terminalResult)
                }
            }
        }
        .environmentObject(state)
    }
}

struct VideoCallPreviewScreen: View {
    @EnvironmentObject private var state: AppState
    let preview: VideoCallPreview

    private var controlPresentation: VideoCallPreviewControlPresentation {
        .resolve(
            cameraEnabled: preview.cameraEnabled,
            isPreparing: preview.isPreparing,
            isStartingCall: preview.isStartingCall,
            unavailableReason: preview.unavailableReason
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("取消") { state.dismissVideoCallPreview() }
                        .foregroundStyle(.white)
                    Spacer()
                    VStack(spacing: 3) {
                        Text("呼叫 \(preview.peer.name)")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: preview.peer.id,
                            compact: true
                        )
                    }
                    Spacer()
                    Color.clear.frame(width: 44)
                }
                .padding()
                .background(Color.black.opacity(0.82))
                ZStack {
                    RTCVideoRendererView(local: true, mirrored: true)
                    if preview.isPreparing {
                        ProgressView("正在准备摄像头…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let reason = preview.unavailableReason {
                    Text(reason)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                }
                if let error = preview.startError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("video_call_preview_error")
                }
                HStack(spacing: 26) {
                    VideoRoundButton(
                        title: controlPresentation.cameraTitle,
                        systemImage: controlPresentation.cameraSystemImage
                    ) {
                        state.setVideoPreviewCameraEnabled(!preview.cameraEnabled)
                    }
                    .disabled(!controlPresentation.cameraControlEnabled)
                    .accessibilityIdentifier("video_call_preview_camera")
                    VideoRoundButton(
                        title: controlPresentation.startTitle,
                        systemImage: preview.isStartingCall ? "hourglass" : "phone.fill",
                        tint: .green
                    ) {
                        state.startOutgoingVideoCallFromPreview()
                    }
                    .disabled(preview.isPreparing || preview.isStartingCall)
                    .accessibilityIdentifier("video_call_preview_start")
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.88))
            }
        }
        .accessibilityIdentifier("video_call_preview")
    }
}

// Keep the video and control slots stable when chrome is hidden or rotated.
// The scrollable controls never cover an edge of the received frame.
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

struct VideoCallScreen: View {
    @EnvironmentObject private var state: AppState
    let session: VoiceCallSession
    var screenshotRemoteFrame = false
    @State private var controlsVisible = true
    @State private var remoteFrameSize = CGSize.zero

    // JHT_MOD_BEGIN RTC_VIDEO_HIDE_AUDIO_SWITCH_ENTRY_20260912 - 修改开始：已接通视频页隐藏“切换语音”入口，保留底层降级能力便于兼容远端状态
    private static let showVideoToAudioSwitchControl = false
    // JHT_MOD_END RTC_VIDEO_HIDE_AUDIO_SWITCH_ENTRY_20260912 - 修改结束
    // JHT_MOD_BEGIN RTC_VIDEO_HIDE_CAMERA_SWITCH_ENTRY_20260912 - 修改开始：已接通视频页隐藏“切换镜头/图片”入口，保留底层切换能力便于后续恢复
    private static let showVideoCameraSwitchControl = false
    // JHT_MOD_END RTC_VIDEO_HIDE_CAMERA_SWITCH_ENTRY_20260912 - 修改结束

    private var current: VoiceCallSession { state.activeVoiceCall ?? session }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        state.setActiveVideoCallMinimized(true)
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 44, height: 44)
                    }
                    Spacer()
                    VStack {
                        Text(current.statusText).font(.headline)
                        if let connectedAt = current.connectedAt {
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
        .onAppear { VideoCallOrientationPolicy.isVideoCallPresented = true }
        .onChange(of: current.id) { _ in
            controlsVisible = true
            remoteFrameSize = .zero
        }
        .onChange(of: current.remoteVideoTrackReady) { ready in
            if !ready { remoteFrameSize = .zero }
        }
        .accessibilityAction(.escape) { controlsVisible = true }
        .onDisappear { VideoCallOrientationPolicy.isVideoCallPresented = false }
    }

    private var videoStage: some View {
        GeometryReader { proxy in
            let region = VideoCallStageLayout.videoRect(source: remoteFrameSize, available: proxy.size)
            ZStack(alignment: .topLeading) {
                remoteVideo
                    .id(current.id)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { controlsVisible.toggle() }
                    .accessibilityAction(named: controlsVisible ? "隐藏通话控制" : "显示通话控制") {
                        controlsVisible.toggle()
                    }
                if current.mediaMode == "video", current.localCameraEnabled {
                    SafeAreaDraggableLocalVideo(
                        mirrored: current.cameraPosition == .front,
                        videoRegion: region
                    )
                    .id(current.id)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteVideo: some View {
        if current.mediaMode == "video",
           current.remoteCameraEnabled,
           current.remoteVideoTrackReady {
            #if DEBUG
            if screenshotRemoteFrame {
                VideoCallSyntheticRemoteFrame()
            } else {
                RTCVideoRendererView(local: false, onVideoSizeChanged: updateRemoteFrameSize)
            }
            #else
            RTCVideoRendererView(local: false, onVideoSizeChanged: updateRemoteFrameSize)
            #endif
        } else {
            VStack(spacing: 14) {
                Image(systemName: current.mediaMode == "video" ? "video.fill" : "phone.fill")
                    .font(.system(size: 52))
                HStack(spacing: 7) {
                    Text(current.peer.name)
                        .font(.title.bold())
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: current.peer.id,
                        compact: false
                    )
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
            if current.isRecoveringNetwork {
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
        if current.mediaMode != "video" { return "语音通话" }
        if !current.remoteCameraEnabled { return "对方已关闭摄像头" }
        return "等待对方画面"
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let error = state.activeCallEndError {
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
                Button { state.toggleActiveCallSpeaker() } label: {
                    Label(current.speakerOn ? "扬声器" : "听筒", systemImage: "speaker.wave.3.fill")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("声音输出")
                .accessibilityValue(current.speakerOn ? "扬声器" : "听筒")
                .accessibilityIdentifier("video_call_speaker_button")
                // JHT_MOD_BEGIN RTC_VIDEO_HIDE_AUDIO_SWITCH_ENTRY_20260912 - 修改开始：仅隐藏本地 UI 入口，不调用降级语音业务
                if current.mediaMode == "video", Self.showVideoToAudioSwitchControl {
                    Button { state.downgradeActiveVideoCallToAudio() } label: {
                        Label("切换语音", systemImage: "phone.fill")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("video_call_downgrade_audio_button")
                }
                // JHT_MOD_END RTC_VIDEO_HIDE_AUDIO_SWITCH_ENTRY_20260912 - 修改结束
                Spacer(minLength: 0)
                // JHT_MOD_BEGIN RTC_VIDEO_HIDE_CAMERA_SWITCH_BUTTON_20260912 - 修改开始：仅隐藏本地 UI 入口，不删除切换镜头业务
                if current.mediaMode == "video", Self.showVideoCameraSwitchControl {
                    Button { state.switchActiveVideoCamera() } label: {
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
                VideoRoundButton(title: current.isMuted ? "取消静音" : "静音",
                                 systemImage: current.isMuted ? "mic.slash.fill" : "mic.fill") {
                    state.toggleActiveCallMuted()
                }
                .accessibilityValue(current.isMuted ? "麦克风已静音" : "麦克风已开启")
                .accessibilityIdentifier("video_call_mute_button")
                if current.mediaMode == "video" {
                    VideoRoundButton(title: current.localCameraEnabled ? "关闭摄像头" : "开启摄像头",
                                     systemImage: current.localCameraEnabled ? "video.fill" : "video.slash.fill") {
                        state.toggleActiveVideoCamera()
                    }
                    .accessibilityValue(current.localCameraEnabled ? "摄像头已开启" : "摄像头已关闭")
                    .accessibilityIdentifier("video_call_camera_button")
                }
                Button { state.endActiveVoiceCall() } label: {
                    VStack(spacing: 7) {
                        Image(systemName: state.isEndingActiveCall ? "hourglass" : "phone.down.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .frame(width: 94, height: 52)
                            .background(Color.red, in: Capsule())
                        Text(state.isEndingActiveCall ? "正在结束…" : "结束通话")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                .disabled(state.isEndingActiveCall)
                .accessibilityIdentifier("video_call_end_button")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
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

struct MinimizedVideoCallBar: View {
    @EnvironmentObject private var state: AppState
    let session: VoiceCallSession

    var body: some View {
        HStack(spacing: 12) {
            Button {
                state.setActiveVideoCallMinimized(false)
            } label: {
                HStack(spacing: 10) {
                Image(systemName: "video.fill")
                Text(session.peer.name)
                    .fontWeight(.bold)
                    .lineLimit(1)
                CertificationPillView(
                    exactUID: session.peer.id,
                    compact: true
                )
                if let connectedAt = session.connectedAt {
                    VideoCallDurationText(connectedAt: connectedAt)
                        .font(.footnote.monospacedDigit())
                } else {
                    Text(session.statusText).font(.footnote)
                }
                Image(systemName: "chevron.up")
                }
            }
            .accessibilityLabel("返回与 \(session.peer.name) 的视频通话")
            VStack(alignment: .leading, spacing: 4) {
                Label(session.isMuted ? "麦克风关" : "麦克风开", systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill")
                Label(session.localCameraEnabled ? "摄像头开" : "摄像头关", systemImage: session.localCameraEnabled ? "video.fill" : "video.slash.fill")
                Label(session.isRecoveringNetwork ? "网络恢复中" : "网络稳定", systemImage: session.isRecoveringNetwork ? "wifi.exclamationmark" : "wifi")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                state.endActiveVoiceCall()
            } label: {
                Image(systemName: state.isEndingActiveCall ? "hourglass" : "phone.down.fill")
                    .frame(width: 48, height: 48)
                    .background(Color.red, in: Circle())
            }
            .disabled(state.isEndingActiveCall)
            .accessibilityLabel(state.isEndingActiveCall ? "正在结束视频通话" : "挂断视频通话")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 72)
        .background(Color.black)
        .accessibilityIdentifier("minimized_video_call")
    }
}

struct VideoCallTerminalResultScreen: View {
    @EnvironmentObject private var state: AppState
    let result: VideoCallTerminalResult

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                AvatarView(
                    name: result.peer.displayName,
                    seed: result.peer.avatarSeed,
                    size: 88,
                    imageURL: result.peer.displayAvatarURL,
                    avatarVersion: result.peer.avatarVersion,
                    avatarUpdatedAt: result.peer.avatarUpdatedAt,
                    certification: state.certificationPresentation(forExactUID: result.peer.id)
                )
                Text(result.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(result.cause)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                if !result.durationText.isEmpty {
                    Label(result.durationText, systemImage: "clock")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                }
                Button(result.nextAction) {
                    state.dismissVideoCallTerminalResult()
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 180, minHeight: 52)
                .accessibilityHint("关闭通话结果并返回聊天")
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video_call_terminal_result")
        .interactiveDismissDisabled(true)
    }
}

enum VideoCallDurationFormatter {
    static func text(connectedAt: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(connectedAt)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct VideoCallDurationText: View {
    let connectedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(VideoCallDurationFormatter.text(connectedAt: connectedAt, now: context.date))
        }
        .accessibilityLabel("通话时长")
    }
}

struct VideoCallLocalPreviewLayout {
    let size: CGSize
    let contentInset: CGFloat
    private let bounds: CGRect

    init(available: CGSize) {
        let width = max(0, available.width)
        let height = max(0, available.height)
        let margin = min(12, min(width, height) / 4)
        let scale = min(1, min((width - 2 * margin) / 124, (height - 2 * margin) / 172))
        size = CGSize(width: 124 * scale, height: 172 * scale)
        contentInset = 3 * scale
        bounds = CGRect(
            x: margin + size.width / 2,
            y: margin + size.height / 2,
            width: max(0, width - 2 * margin - size.width),
            height: max(0, height - 2 * margin - size.height)
        )
    }

    func center(for point: CGPoint?, snapping: Bool = false) -> CGPoint {
        let proposed = point ?? CGPoint(x: bounds.maxX, y: bounds.minY)
        let x = min(max(proposed.x, bounds.minX), bounds.maxX)
        return CGPoint(
            x: snapping ? (x < bounds.midX ? bounds.minX : bounds.maxX) : x,
            y: min(max(proposed.y, bounds.minY), bounds.maxY)
        )
    }
}

private struct SafeAreaDraggableLocalVideo: View {
    let mirrored: Bool
    let videoRegion: CGRect
    @State private var center: CGPoint?
    @State private var dragOrigin: CGPoint?

    private let coordinateSpaceName = "video-call-local-preview"

    var body: some View {
        let layout = VideoCallLocalPreviewLayout(available: videoRegion.size)
        RTCVideoRendererView(local: true, mirrored: mirrored)
            .padding(layout.contentInset)
            .frame(width: layout.size.width, height: layout.size.height)
            .background {
                RoundedRectangle(cornerRadius: layout.contentInset)
                    .strokeBorder(.white.opacity(0.75), lineWidth: min(2, layout.contentInset))
            }
            .overlay(alignment: .bottomLeading) {
                Text("我").font(.caption2.bold()).padding(5)
                    .foregroundStyle(.white).background(Color.black.opacity(0.55))
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .bottomLeading)
                    .clipped()
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(coordinateSpaceName))
                    .onChanged { value in
                        let origin = dragOrigin ?? layout.center(for: center)
                        if dragOrigin == nil { dragOrigin = origin }
                        center = layout.center(for: CGPoint(x: origin.x + value.translation.width,
                                                           y: origin.y + value.translation.height))
                    }
                    .onEnded { value in
                        let origin = dragOrigin ?? layout.center(for: center)
                        center = layout.center(for: CGPoint(x: origin.x + value.translation.width,
                                                           y: origin.y + value.translation.height), snapping: true)
                        dragOrigin = nil
                    }
            )
            .onTapGesture { } // A preview tap never reaches the remote visibility gesture.
            .accessibilityLabel("本人视频小窗")
            .accessibilityHint("可在对方视频区域内拖动")
            .accessibilityAdjustableAction { direction in
                let point = layout.center(for: center)
                center = layout.center(for: CGPoint(x: point.x,
                    y: point.y + (direction == .increment ? 40 : -40)))
            }
            // Position the already interactive preview; the positioning region
            // must not become a gesture target covering the remote video.
            .position(layout.center(for: center))
            .frame(width: videoRegion.width, height: videoRegion.height, alignment: .topLeading)
            .coordinateSpace(name: coordinateSpaceName)
            .offset(x: videoRegion.minX, y: videoRegion.minY)
            .onChange(of: videoRegion) { _ in
                center = layout.center(for: center)
                dragOrigin = nil
            }
    }
}

private struct VideoRoundButton: View {
    let title: String
    let systemImage: String
    var tint: Color = Color.white.opacity(0.2)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(tint, in: Circle())
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
        }
    }
}

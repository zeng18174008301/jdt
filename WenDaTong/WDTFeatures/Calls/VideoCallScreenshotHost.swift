import SwiftUI

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

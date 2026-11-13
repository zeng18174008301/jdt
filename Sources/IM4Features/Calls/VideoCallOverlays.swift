import Foundation
import SwiftUI
import IM4DesignSystem

public struct MinimizedVideoCallInput: Sendable {
    let peerName: String
    let connectedAt: Date?
    let statusText: String
    let isMuted: Bool
    let localCameraEnabled: Bool
    let isRecoveringNetwork: Bool
    let isEnding: Bool
    public init(peerName: String, connectedAt: Date?, statusText: String, isMuted: Bool, localCameraEnabled: Bool, isRecoveringNetwork: Bool, isEnding: Bool) {
        self.peerName = peerName
        self.connectedAt = connectedAt
        self.statusText = statusText
        self.isMuted = isMuted
        self.localCameraEnabled = localCameraEnabled
        self.isRecoveringNetwork = isRecoveringNetwork
        self.isEnding = isEnding
    }
}

public struct MinimizedVideoCallBarContent<Certification: View>: View {
    let input: MinimizedVideoCallInput
    let certification: () -> Certification
    let onRestore: () -> Void
    let onEnd: () -> Void
    public init(input: MinimizedVideoCallInput, @ViewBuilder certification: @escaping () -> Certification,
                onRestore: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.input = input; self.certification = certification; self.onRestore = onRestore; self.onEnd = onEnd
    }
    public var body: some View {
        HStack(spacing: 12) {
            Button {
                onRestore()
            } label: {
                HStack(spacing: 10) {
                Image(systemName: "video.fill")
                Text(input.peerName)
                    .fontWeight(.bold)
                    .lineLimit(1)
                certification()
                if let connectedAt = input.connectedAt {
                    VideoCallDurationText(connectedAt: connectedAt)
                        .font(.footnote.monospacedDigit())
                } else {
                    Text(input.statusText).font(.footnote)
                }
                Image(systemName: "chevron.up")
                }
            }
            .accessibilityLabel("返回与 \(input.peerName) 的视频通话")
            VStack(alignment: .leading, spacing: 4) {
                Label(input.isMuted ? "麦克风关" : "麦克风开", systemImage: input.isMuted ? "mic.slash.fill" : "mic.fill")
                Label(input.localCameraEnabled ? "摄像头开" : "摄像头关", systemImage: input.localCameraEnabled ? "video.fill" : "video.slash.fill")
                Label(input.isRecoveringNetwork ? "网络恢复中" : "网络稳定", systemImage: input.isRecoveringNetwork ? "wifi.exclamationmark" : "wifi")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                onEnd()
            } label: {
                Image(systemName: input.isEnding ? "hourglass" : "phone.down.fill")
                    .frame(width: 48, height: 48)
                    .background(Color.red, in: Circle())
            }
            .disabled(input.isEnding)
            .accessibilityLabel(input.isEnding ? "正在结束视频通话" : "挂断视频通话")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 72)
        .background(Color.black)
        .accessibilityIdentifier("minimized_video_call")
    }
}

public struct VideoCallTerminalInput: Sendable {
    let title: String
    let cause: String
    let durationText: String
    let nextAction: String
    public init(title: String, cause: String, durationText: String, nextAction: String) {
        self.title = title
        self.cause = cause
        self.durationText = durationText
        self.nextAction = nextAction
    }
}

public struct VideoCallTerminalResultContent<Avatar: View>: View {
    let input: VideoCallTerminalInput
    let avatar: () -> Avatar
    let onClose: () -> Void
    public init(input: VideoCallTerminalInput, @ViewBuilder avatar: @escaping () -> Avatar,
                onClose: @escaping () -> Void) {
        self.input = input; self.avatar = avatar; self.onClose = onClose
    }
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                avatar()
                Text(input.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(input.cause)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                if !input.durationText.isEmpty {
                    Label(input.durationText, systemImage: "clock")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                }
                Button(input.nextAction) {
                    onClose()
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

public enum VideoCallDurationFormatter {
    public static func text(connectedAt: Date, now: Date) -> String {
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

struct VideoCallDurationText: View {
    let connectedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(VideoCallDurationFormatter.text(connectedAt: connectedAt, now: context.date))
        }
        .accessibilityLabel("通话时长")
    }
}

struct VideoRoundButton: View {
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

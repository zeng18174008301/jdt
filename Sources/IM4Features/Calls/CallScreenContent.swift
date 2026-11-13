import Foundation
import SwiftUI
import UIKit
import IM4DesignSystem

public struct IncomingCallScreenInput: Sendable {
    let callerName: String
    let enterprise: String
    let department: String
    let title: String
    let isVideo: Bool
    let answerMode: String?
    public init(callerName: String, enterprise: String, department: String, title: String,
                isVideo: Bool, answerMode: String?) {
        self.callerName = callerName; self.enterprise = enterprise; self.department = department
        self.title = title; self.isVideo = isVideo; self.answerMode = answerMode
    }
}

public struct IncomingCallScreenContent<Avatar: View, Certification: View, Toast: View>: View {
    let input: IncomingCallScreenInput
    let avatar: () -> Avatar
    let certification: () -> Certification
    let toast: () -> Toast
    let onDecline: () -> Void
    let onAnswer: () -> Void
    let onAnswerAudio: () -> Void
    private var isAnswering: Bool { input.answerMode != nil }
    private var kindTitle: String { input.isVideo ? "视频来电" : "语音来电" }
    private var kindIcon: String { input.isVideo ? "video.fill" : "phone.fill" }
    public init(input: IncomingCallScreenInput, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification,
                @ViewBuilder toast: @escaping () -> Toast, onDecline: @escaping () -> Void,
                onAnswer: @escaping () -> Void, onAnswerAudio: @escaping () -> Void) {
        self.input = input; self.avatar = avatar; self.certification = certification; self.toast = toast
        self.onDecline = onDecline; self.onAnswer = onAnswer; self.onAnswerAudio = onAnswerAudio
    }
    public var body: some View {
        ZStack {
            LinearGradient(
                colors: input.isVideo
                    ? [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.07, green: 0.08, blue: 0.16)]
                    : [Color(red: 0.08, green: 0.20, blue: 0.29), Color(red: 0.04, green: 0.09, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        Label(kindTitle, systemImage: kindIcon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .accessibilityIdentifier("incoming_call_kind")
                            .padding(.top, 24)

                        Spacer(minLength: 16)
                        avatar()
                        VStack(spacing: 12) {
                            Text(input.callerName)
                                .font(.largeTitle.bold())
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("incoming_call_caller")
                            certification()
                            if !callerDetails.isEmpty {
                                Text(callerDetails)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        Text(input.isVideo ? "邀请你进行视频通话" : "邀请你进行语音通话")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 24)

                        // Render metadata only. Media and permission work stays in the
                        // existing explicit answer actions; there is no camera preview.
                        if input.isVideo {
                            Text("接听前不会开启摄像头")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        toast()
                        HStack(alignment: .top, spacing: 64) {
                            callButton(title: "拒绝", icon: "phone.down.fill", color: IMColor.danger,
                                       identifier: "incoming_call_reject_button", disabled: false) {
                                onDecline()
                            }
                            callButton(title: isAnswering ? "正在接听" : "接听",
                                       icon: kindIcon, color: IMColor.success,
                                       identifier: input.isVideo ? "incoming_video_answer_video_button" : "incoming_voice_answer_button",
                                       disabled: isAnswering) {
                                onAnswer()
                            }
                        }
                        if input.isVideo {
                            Button {
                                onAnswerAudio()
                            } label: {
                                Label(input.answerMode == "audio" ? "正在语音接听" : "仅语音接听",
                                      systemImage: "phone.fill")
                                    .font(.body.weight(.semibold))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(isAnswering)
                            .opacity(isAnswering ? 0.5 : 1)
                            .accessibilityIdentifier("incoming_video_answer_audio_button")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier(input.isVideo ? "incoming_video_call" : "incoming_voice_call")
    }

    private var callerDetails: String {
        [input.enterprise, input.department, input.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            .joined(separator: " · ")
    }

    private func callButton(title: String, icon: String, color: Color, identifier: String,
                            disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(color))
                Text(title).font(.body.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

public struct IncomingCallToastMessage: View {
    let message: String?
    public init(message: String?) { self.message = message }
    public var body: some View {
        if let message {
            Text(message)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("incoming_call_action_message")
        }
    }
}

public struct RTCIncomingCallCardContent<Avatar: View, Certification: View>: View {
    let callerName: String
    let isVideo: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onDecline: () -> Void
    let onAnswer: () -> Void
    public init(callerName: String, isVideo: Bool, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification,
                onDecline: @escaping () -> Void, onAnswer: @escaping () -> Void) {
        self.callerName = callerName; self.isVideo = isVideo; self.avatar = avatar
        self.certification = certification; self.onDecline = onDecline; self.onAnswer = onAnswer
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 5) {
                    Text("好友正在呼叫")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    HStack(spacing: 6) {
                        Text("\(callerName) · \(isVideo ? "视频通话" : "语音通话")")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                            .lineLimit(1)
                        certification()
                    }
                }
                Spacer()
                StatusPill(title: "来电中", color: IMColor.success)
            }
            HStack(spacing: 10) {
                Button {
                    onDecline()
                } label: {
                    Label("拒绝", systemImage: "phone.down.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(IMColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.danger.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("incoming_voice_card_reject_button")
                Button {
                    onAnswer()
                } label: {
                    Label("接听", systemImage: isVideo ? "video.fill" : "phone.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.success))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(isVideo ? "incoming_video_card_answer_button" : "incoming_voice_card_answer_button")
            }
        }
        .im4PlainCard(radius: 24)
    }
}

public struct VoiceCallScreenInput: Sendable {
    let peerName: String
    let statusText: String
    let direction: String
    let connectedAt: Date?
    let speakerOn: Bool
    let isMuted: Bool
    public init(peerName: String, statusText: String, direction: String, connectedAt: Date?,
                speakerOn: Bool, isMuted: Bool) {
        self.peerName = peerName; self.statusText = statusText; self.direction = direction
        self.connectedAt = connectedAt; self.speakerOn = speakerOn; self.isMuted = isMuted
    }
}

public struct VoiceCallScreenContent<Avatar: View, Certification: View>: View {
    let input: VoiceCallScreenInput
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onToggleMuted: () -> Void
    let onToggleSpeaker: () -> Void
    let onEnd: () -> Void
    @State private var isShowingKeypad = false
    public init(input: VoiceCallScreenInput, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification,
                onToggleMuted: @escaping () -> Void, onToggleSpeaker: @escaping () -> Void,
                onEnd: @escaping () -> Void) {
        self.input = input; self.avatar = avatar; self.certification = certification
        self.onToggleMuted = onToggleMuted; self.onToggleSpeaker = onToggleSpeaker; self.onEnd = onEnd
    }
    public var body: some View {
        let call = input
        ZStack {
            LinearGradient(colors: [Color(im4Hex: 0x101828), Color(im4Hex: 0x1B2559), Color(im4Hex: 0x5D6BFF)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                HStack {
                    StatusPill(title: callStageTitle(call), color: callStageColor(call), filled: true)
                    Spacer()
                    Text("语音通话")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(.top, 22)

                Spacer()

                avatar()
                    .shadow(color: .black.opacity(0.24), radius: 28, y: 16)
                    .accessibilityIdentifier("voice_call_peer_profile_disabled")
                    .accessibilityLabel("通话对象头像")
                    .accessibilityHint("通话期间不能打开用户资料")
                    .accessibilityAddTraits(.isStaticText)
                TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                    VStack(spacing: 8) {
                        HStack(spacing: 7) {
                            Text(input.peerName)
                                .font(.system(size: 30, weight: .black))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            certification()
                        }
                        Text(callRuntimeText(call, now: timeline.date))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.70))
                            .monospacedDigit()
                        HStack(spacing: 8) {
                            VoiceCallStateChip(
                                symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill",
                                title: call.speakerOn ? "免提已开" : "听筒模式"
                            )
                            VoiceCallStateChip(
                                symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                                title: call.isMuted ? "已静音" : "麦克风开启"
                            )
                        }
                        .padding(.top, 6)
                    }
                }

                Spacer()

                if isShowingKeypad {
                    VoiceCallKeypadPanel {
                        isShowingKeypad = false
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 8) {
                    CallControl(
                        symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: call.isMuted ? "取消静音" : "静音",
                        isActive: call.isMuted
                    ) {
                        onToggleMuted()
                    }
                    .accessibilityIdentifier("voice_call_mute_button")
                    CallControl(
                        symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill",
                        title: call.speakerOn ? "关闭免提" : "打开免提",
                        isActive: call.speakerOn
                    ) {
                        onToggleSpeaker()
                    }
                    .accessibilityIdentifier("voice_call_speaker_button")
                    CallControl(symbol: "circle.grid.3x3.fill", title: "键盘") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            isShowingKeypad.toggle()
                        }
                    }
                    CallControl(symbol: "phone.down.fill", title: "挂断", danger: true) {
                        onEnd()
                    }
                    .accessibilityIdentifier("voice_call_end_button")
                }
                .padding(.bottom, 42)
                .zIndex(2)
            }
            .padding(.horizontal, 18)
        }
        .accessibilityIdentifier("voice_call_screen")
        .interactiveDismissDisabled(true)
    }

    private func callStageTitle(_ call: VoiceCallScreenInput) -> String {
        if call.statusText == "通话中" {
            return "通话中"
        }
        if call.direction == "来电" {
            return "来电中"
        }
        return "等待接听"
    }

    private func callStageColor(_ call: VoiceCallScreenInput) -> Color {
        call.statusText == "通话中" ? IMColor.success : IMColor.brand
    }

    private func callRuntimeText(_ call: VoiceCallScreenInput, now: Date) -> String {
        guard call.statusText == "通话中", let connectedAt = call.connectedAt else {
            return call.statusText
        }
        let total = max(0, Int(now.timeIntervalSince(connectedAt).rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct VoiceCallStateChip: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
            Text(title)
                .font(.system(size: 11, weight: .black))
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.14)))
    }
}

private struct VoiceCallKeypadPanel: View {
    let onClose: () -> Void
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("通话键盘")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起通话键盘")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(key)
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 46)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("通话按键 \(key)")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        )
    }
}

private struct CallControl: View {
    let symbol: String
    let title: String
    var isActive = false
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(danger || isActive ? .white : .white.opacity(0.86))
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(controlBackground))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.78))
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 88)
        .contentShape(Rectangle())
    }

    private var controlBackground: Color {
        if danger { return IMColor.danger }
        if isActive { return .white.opacity(0.30) }
        return .white.opacity(0.16)
    }
}

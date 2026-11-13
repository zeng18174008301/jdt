import IM4Domain
import IM4DesignSystem
import SwiftUI
import UIKit

struct VoiceWaveformBars: View {
    let samples: [Int]
    let active: Bool
    let outgoing: Bool
    var height: CGFloat = 28
    var barCount: Int = 24
    var fitsAvailableWidth = false // WDT_IOS1_VOICE_DURATION_LAYOUT_20261113

    private var displaySamples: [Int] {
        VoiceMessagePayload.normalizedWaveform(samples.isEmpty ? Array(repeating: 18, count: barCount) : samples)
    }

    // WDT_IOS1_VOICE_DURATION_LAYOUT_20261113_BEGIN
    var body: some View {
        let visibleSamples = Array(displaySamples.prefix(barCount))
        let naturalWidth = CGFloat(max(1, visibleSamples.count * 5 - 2))
        Group {
            if fitsAvailableWidth {
                GeometryReader { geometry in
                    bars(visibleSamples, scale: min(1, geometry.size.width / naturalWidth))
                        .frame(height: height)
                }
                .frame(idealWidth: naturalWidth, maxWidth: naturalWidth)
            } else {
                bars(visibleSamples, scale: 1)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func bars(_ samples: [Int], scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 2 * scale) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(barColor.opacity(active ? 0.98 : 0.72))
                    .frame(width: 3 * scale, height: max(4, CGFloat(sample) / 100.0 * height))
            }
        }
    }
    // WDT_IOS1_VOICE_DURATION_LAYOUT_20261113_END

    private var barColor: Color {
        outgoing ? .white : IMColor.brand
    }
}

struct VoiceRecordingOverlay: View {
    let elapsedMS: Int
    let waveform: [Int]
    let isCanceling: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCanceling ? "xmark.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(isCanceling ? IMColor.danger : IMColor.brand)
            VStack(alignment: .leading, spacing: 5) {
                Text(isCanceling ? "松开取消" : "正在录音 \(VoiceMessagePayload.durationLabel(durationMS: elapsedMS))")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.ink)
                VoiceWaveformBars(samples: waveform, active: true, outgoing: false, height: 18, barCount: 32)
            }
            Spacer()
            Text("60s")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.muted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill((isCanceling ? IMColor.danger : IMColor.brand).opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke((isCanceling ? IMColor.danger : IMColor.brand).opacity(0.18)))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCanceling ? "松开取消语音消息" : "正在录制语音消息")
    }
}

struct VoiceRecordingFeedbackPanel: View {
    let feedback: VoiceRecordingComposerFeedback

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(IMColor.warning)
            Text(feedback.message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IMColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(IMColor.warning.opacity(0.20))
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(feedback.accessibilityIdentifier)
        .accessibilityLabel(feedback.message)
        .accessibilityAddTraits(.isStaticText)
    }
}

public struct VoiceRecordingPreviewInput {
    public let durationMS: Int
    public let waveform: [Int]
    public let isPlaying: Bool
    public let progress: Double
    public let remainingLabel: String?

    public init(durationMS: Int,
        waveform: [Int],
        isPlaying: Bool,
        progress: Double,
        remainingLabel: String? = nil) {
        self.durationMS = durationMS
        self.waveform = waveform
        self.isPlaying = isPlaying
        self.progress = progress
        self.remainingLabel = remainingLabel
    }
}

struct VoiceRecordingPreviewPanel: View {
    let input: VoiceRecordingPreviewInput?
    let togglePlayback: () -> Void
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        if let input {
#if DEBUG
            let _ = VoiceRecordingPreviewDiagnostics.render?(VoiceRecordingPreviewProbe(
                input: input, togglePlayback: togglePlayback, send: send, cancel: cancel))
#endif
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: input.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(IMColor.brand))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_voice_preview_play_button")
                    .accessibilityLabel(input.isPlaying ? "暂停预览语音" : "回放预览语音")

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("语音待发送")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Spacer()
                            Text(previewCountdownText(input))
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(IMColor.muted)
                        }
                        VoiceWaveformBars(samples: input.waveform, active: input.isPlaying, outgoing: false, height: 18, barCount: 36)
                        ProgressView(value: input.progress)
                            .tint(IMColor.brand)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        cancel()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.danger)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Capsule().fill(IMColor.danger.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_voice_preview_cancel_button")

                    Button {
                        send()
                    } label: {
                        Label("发送", systemImage: "paperplane.fill")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Capsule().fill(IMColor.brand))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_voice_preview_send_button")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(IMColor.brand.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.brand.opacity(0.16)))
            )
            .accessibilityIdentifier("chat_voice_preview_panel")
            .accessibilityElement(children: .contain)
        }
    }

    private func previewCountdownText(_ input: VoiceRecordingPreviewInput) -> String {
        guard let remaining = input.remainingLabel, input.isPlaying else {
            return VoiceMessagePayload.durationLabel(durationMS: input.durationMS)
        }
        return remaining.isEmpty ? "0秒" : "剩余 \(remaining)"
    }
}

#if DEBUG
struct VoiceRecordingPreviewProbe {
    let input: VoiceRecordingPreviewInput
    let togglePlayback: () -> Void
    let send: () -> Void
    let cancel: () -> Void
}
@MainActor enum VoiceRecordingPreviewDiagnostics {
    static var render: ((VoiceRecordingPreviewProbe) -> Void)?
}
#endif

public struct VoiceRecordPad: View {
    let isRecording: Bool
    let isRequesting: Bool
    let isFinalizing: Bool
    let elapsedMS: Int
    let isCanceling: Bool
    let start: () -> Void
    let finish: (Bool) -> Void
    let updateCanceling: (Bool) -> Void

    public var body: some View {
        let drag = DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isRecording else { return }
                updateCanceling(value.translation.height < -54)
            }
            .onEnded { value in
                guard isRecording else { return }
                let shouldCancel = value.translation.height < -54
                updateCanceling(false)
                finish(shouldCancel)
            }

        Button {
            if isRequesting || isRecording {
                finish(false)
            } else {
                start()
            }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(isCanceling ? IMColor.danger : IMColor.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isCanceling ? IMColor.danger.opacity(0.10) : Color(im4Hex: 0xF3F5FA))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke((isRequesting || isRecording || isFinalizing) ? IMColor.brand.opacity(0.26) : .clear, lineWidth: 1))
                )
        }
            .buttonStyle(.plain)
            .disabled(isFinalizing)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .simultaneousGesture(drag)
            .accessibilityIdentifier("chat_voice_record_pad")
            .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        if isCanceling { return "松开取消" }
        if isRequesting { return "正在启动录音 · 点击取消" }
        if isFinalizing { return "正在生成语音预览…" }
        if isRecording {
            let duration = VoiceMessagePayload.durationLabel(durationMS: elapsedMS)
            return duration.isEmpty ? "点击发送 · 上滑取消" : "\(duration) · 点击发送"
        }
        return "点击开始录音"
    }

    private var accessibilityLabel: String {
        if isRequesting { return "取消录音启动" }
        if isFinalizing { return "正在生成语音预览" }
        return isRecording ? "停止并生成语音预览" : "开始录制语音消息"
    }

    public init(isRecording: Bool,
        isRequesting: Bool,
        isFinalizing: Bool,
        elapsedMS: Int,
        isCanceling: Bool,
        start: @escaping () -> Void,
        finish: @escaping (Bool) -> Void,
        updateCanceling: @escaping (Bool) -> Void) {
        self.isRecording = isRecording
        self.isRequesting = isRequesting
        self.isFinalizing = isFinalizing
        self.elapsedMS = elapsedMS
        self.isCanceling = isCanceling
        self.start = start
        self.finish = finish
        self.updateCanceling = updateCanceling
    }
}

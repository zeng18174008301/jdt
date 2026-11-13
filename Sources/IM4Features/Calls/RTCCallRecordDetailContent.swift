// WDT_IOS1_FEATURES_CALLS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct RTCCallRecordDetailContent<Avatar: View, Certification: View>: View {
    let peerName: String
    let peerUserIDText: String
    let status: String
    let callTypeText: String
    let startedAtText: String
    let endedAtText: String
    let durationText: String
    let canStartVoiceCall: Bool
    let voiceUnavailableReason: String?
    let canStartVideoCall: Bool
    let videoUnavailableReason: String?
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onVoiceDial: () -> Void
    let onVideoDial: () -> Void

    public init(peerName: String, peerUserIDText: String, status: String, callTypeText: String,
                startedAtText: String, endedAtText: String, durationText: String, canStartVoiceCall: Bool,
                voiceUnavailableReason: String?, canStartVideoCall: Bool, videoUnavailableReason: String?,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                onVoiceDial: @escaping () -> Void, onVideoDial: @escaping () -> Void) {
        self.peerName = peerName
        self.peerUserIDText = peerUserIDText
        self.status = status
        self.callTypeText = callTypeText
        self.startedAtText = startedAtText
        self.endedAtText = endedAtText
        self.durationText = durationText
        self.canStartVoiceCall = canStartVoiceCall
        self.voiceUnavailableReason = voiceUnavailableReason
        self.canStartVideoCall = canStartVideoCall
        self.videoUnavailableReason = videoUnavailableReason
        self.avatar = avatar
        self.certification = certification
        self.onVoiceDial = onVoiceDial
        self.onVideoDial = onVideoDial
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(IMColor.line)
                .frame(width: 42, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(peerName)
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        certification()
                    }
                    Text("用户ID \(peerUserIDText)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                StatusPill(title: status, color: statusColor)
            }

            VStack(spacing: 0) {
                detailRow(title: "呼叫类型", value: callTypeText)
                detailDivider
                detailRow(title: "开始时间", value: startedAtText)
                detailDivider
                detailRow(title: "结束时间", value: endedAtText)
                detailDivider
                detailRow(title: "总时长", value: durationText)
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(IMColor.line.opacity(0.78), lineWidth: 1))
            )

            VStack(alignment: .leading, spacing: 8) {
                if !canStartVoiceCall, let voiceUnavailableReason {
                    unavailableReason(kind: .voice, text: voiceUnavailableReason)
                }
                if !canStartVideoCall, let videoUnavailableReason {
                    unavailableReason(kind: .video, text: videoUnavailableReason)
                }
            }

            HStack(spacing: 12) {
                redialButton(
                    kind: .voice,
                    isEnabled: canStartVoiceCall,
                    unavailableReason: voiceUnavailableReason,
                    identifier: "rtc_recent_call_detail_voice_button"
                ) {
                    onVoiceDial()
                }
                redialButton(
                    kind: .video,
                    isEnabled: canStartVideoCall,
                    unavailableReason: videoUnavailableReason,
                    identifier: "rtc_recent_call_detail_video_button"
                ) {
                    onVideoDial()
                }
            }
        }
        .padding(18)
        .background(IMColor.page.ignoresSafeArea())
    }

    private var statusColor: Color {
        if status.contains("拒") || status.contains("未") || status.contains("忙") {
            return IMColor.danger
        }
        if status.contains("结束") || status.contains("已") {
            return IMColor.success
        }
        return IMColor.brand
    }

    private var detailDivider: some View {
        Rectangle()
            .fill(IMColor.line.opacity(0.72))
            .frame(height: 1)
    }

    private func unavailableReason(kind: RTCCallActionKind, text: String) -> some View {
        Label(text, systemImage: kind.unavailableSystemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IMColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(kind.title)不可用：\(text)")
    }

    private func redialButton(
        kind: RTCCallActionKind,
        isEnabled: Bool,
        unavailableReason: String?,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(
                kind.title,
                systemImage: isEnabled ? kind.systemImage : kind.unavailableSystemImage
            )
            .font(.caption.weight(.black))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isEnabled ? kind.accentColor : IMColor.muted.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("重新\(kind.title)")
        .accessibilityHint(isEnabled ? "向该好友重新发起\(kind.title)" : (unavailableReason ?? "暂无法发起\(kind.title)"))
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
    }

}
// WDT_IOS1_FEATURES_CALLS_UI_20261111_END

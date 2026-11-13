// WDT_IOS1_FEATURES_CALLS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

import IM4Domain

public struct RTCCallHistoryContent<Incoming: View, CallRow: View>: View {
    let calls: [CallRecord]
    let newVoiceCallUnavailableReason: String?
    let newVideoCallUnavailableReason: String?
    let incomingCall: () -> Incoming
    let callRow: (CallRecord) -> CallRow
    let onRequestVoice: () -> Void
    let onRequestVideo: () -> Void
    let onSelectCall: (CallRecord) -> Void

    public init(calls: [CallRecord], voiceUnavailable: String?, videoUnavailable: String?,
                @ViewBuilder incomingCall: @escaping () -> Incoming, @ViewBuilder callRow: @escaping (CallRecord) -> CallRow,
                onRequestVoice: @escaping () -> Void, onRequestVideo: @escaping () -> Void,
                onSelectCall: @escaping (CallRecord) -> Void) {
        self.calls = calls
        self.newVoiceCallUnavailableReason = voiceUnavailable
        self.newVideoCallUnavailableReason = videoUnavailable
        self.incomingCall = incomingCall
        self.callRow = callRow
        self.onRequestVoice = onRequestVoice
        self.onRequestVideo = onRequestVideo
        self.onSelectCall = onSelectCall
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "phone.badge.waveform.fill")
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 66, height: 66)
                                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("1对1沟通")
                                    .font(.system(size: 22, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("好友来电通知、接听和最近通话记录")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                            }
                        }
                        HStack(spacing: 12) {
                            Button {
                                onRequestVoice()
                            } label: {
                                Label("语音通话", systemImage: "phone.arrow.up.right.fill")
                                    .font(.callout.weight(.black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .foregroundStyle(IMColor.brand)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(IMColor.brand.opacity(0.10))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(newVoiceCallUnavailableReason != nil)
                            .accessibilityIdentifier("rtc_new_voice_call_button")
                            .accessibilityLabel("发起语音通话")
                            .accessibilityHint(newVoiceCallUnavailableReason ?? "选择好友后发起一对一语音通话")

                            Button {
                                onRequestVideo()
                            } label: {
                                Label(
                                    "视频通话",
                                    systemImage: newVideoCallUnavailableReason == nil ? "video.fill" : "video.slash"
                                )
                                .font(.callout.weight(.black))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .foregroundStyle(newVideoCallUnavailableReason == nil ? IMColor.violet : IMColor.muted)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill((newVideoCallUnavailableReason == nil ? IMColor.violet : IMColor.muted).opacity(0.10))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(newVideoCallUnavailableReason != nil)
                            .accessibilityIdentifier("rtc_new_video_call_button")
                            .accessibilityLabel("发起视频通话")
                            .accessibilityHint(newVideoCallUnavailableReason ?? "选择好友后发起一对一视频通话")
                        }
                    }
                    .im4GlassCard(radius: 28)

                    incomingCall()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("最近通话")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        if calls.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "phone.badge.clock.fill")
                                    .font(.system(size: 28, weight: .black))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(width: 64, height: 64)
                                    .background(Circle().fill(IMColor.brand.opacity(0.10)))
                                VStack(spacing: 6) {
                                    Text("暂无通话记录")
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                    Text("好友来电、已接和未接通话会在这里展示。")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(IMColor.muted)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .im4PlainCard(radius: 24)
                        } else {
                            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：最近通话改为懒加载行，避免切入沟通 Tab 时一次性渲染全部记录
                            LazyVStack(spacing: 12) {
                                ForEach(calls) { call in
                                    Button {
                                        onSelectCall(call)
                                    } label: {
                                        callRow(call)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("rtc_recent_call_\(call.id)")
                                }
                            }
                            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
    }
}
// WDT_IOS1_FEATURES_CALLS_UI_20261111_END

// WDT_IOS1_FEATURES_CALLS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

import IM4Domain

public struct RTCCallRecordRowContent<Avatar: View, Certification: View>: View {
    let call: CallRecord

    let avatar: () -> Avatar
    let certification: () -> Certification

    public init(call: CallRecord, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.call = call
        self.avatar = avatar
        self.certification = certification
    }

    private var accentColor: Color {
        switch call.direction {
        case .outgoing:
            return IMColor.brand
        case .incoming:
            return IMColor.success
        case .system:
            return IMColor.muted
        }
    }

    private var symbol: String {
        switch call.direction {
        case .outgoing:
            return "phone.arrow.up.right.fill"
        case .incoming:
            return "phone.arrow.down.left.fill"
        case .system:
            return "shield.lefthalf.filled"
        }
    }

    private var directionTitle: String {
        switch call.direction {
        case .outgoing:
            return "我呼出"
        case .incoming:
            return "对方来电"
        case .system:
            return "系统"
        }
    }

    private var statusColor: Color {
        if call.status.contains("拒") || call.status.contains("未") {
            return IMColor.danger
        }
        if call.status.contains("结束") || call.status.contains("已") {
            return IMColor.success
        }
        return IMColor.muted
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                avatar()
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(accentColor))
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(call.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                certification()
                HStack(spacing: 7) {
                    Text(directionTitle)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accentColor.opacity(0.10)))
                    Text(call.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(call.time)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                StatusPill(title: call.status, color: statusColor)
            }
        }
        .im4PlainCard(radius: 20)
    }
}
// WDT_IOS1_FEATURES_CALLS_UI_20261111_END

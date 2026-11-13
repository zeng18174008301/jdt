// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct InboxAnnouncementRow: View {
    let item: InboxItem

    public init(item: InboxItem) { self.item = item }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(im4Hex: item.accentHex).opacity(item.isRead ? 0.12 : 0.20))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: item.isRead ? "envelope.open.fill" : "envelope.badge.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(im4Hex: item.accentHex))
                )
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    if !item.isRead {
                        Text("未读")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(IMColor.danger))
                    }
                    Spacer()
                    Text(item.time)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                Text(item.subtitle)
                    .font(.system(size: 12, weight: item.isRead ? .medium : .semibold))
                    .foregroundStyle(item.isRead ? IMColor.muted : IMColor.ink.opacity(0.76))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(item.isRead ? IMColor.card : Color(im4Hex: 0xEEF3FF))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(item.isRead ? IMColor.line : Color(im4Hex: item.accentHex).opacity(0.32), lineWidth: 1)
                )
                .shadow(color: Color(im4Hex: item.accentHex, alpha: item.isRead ? 0.04 : 0.10), radius: item.isRead ? 12 : 20, y: item.isRead ? 6 : 10)
        )
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

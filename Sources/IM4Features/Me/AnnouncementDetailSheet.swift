// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct AnnouncementDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: InboxItem

    public init(item: InboxItem) { self.item = item }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(im4Hex: item.accentHex).opacity(0.14))
                        .frame(width: 54, height: 54)
                        .overlay(
                            Image(systemName: "megaphone.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color(im4Hex: item.accentHex))
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("公告详情")
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        HStack(spacing: 8) {
                            StatusPill(title: "公告", color: Color(im4Hex: item.accentHex))
                            Text(item.time)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.white.opacity(0.82)))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.45)
                    Text(item.subtitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineSpacing(5)
                        .foregroundStyle(IMColor.ink.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(IMColor.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(IMColor.line, lineWidth: 1)
                        )
                )

                Button {
                    dismiss()
                } label: {
                    Label("我知道了", systemImage: "checkmark")
                        .font(.system(size: 16, weight: .black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(IMColor.brand))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

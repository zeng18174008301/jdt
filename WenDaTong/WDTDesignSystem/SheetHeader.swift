// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_BEGIN
import SwiftUI

public struct SheetHeader: View {
    public init(symbol: String, title: String, subtitle: String, showsCloseButton: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.showsCloseButton = showsCloseButton
    }
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    let title: String
    let subtitle: String
    var showsCloseButton = false

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(IMColor.brand))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(IMColor.ink)
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showsCloseButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white.opacity(0.86)))
                        .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
        }
    }
}
// WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110_END

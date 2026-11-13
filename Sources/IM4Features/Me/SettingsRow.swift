// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct SettingsRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var badgeCount: Int = 0
    var tint: Color = IMColor.brand
    var titleColor: Color = IMColor.ink
    var action: (() -> Void)?

    public init(symbol: String, title: String, subtitle: String? = nil, badgeCount: Int = 0,
                tint: Color = IMColor.brand, titleColor: Color = IMColor.ink, action: (() -> Void)? = nil) {
        self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.badgeCount = badgeCount
        self.tint = tint; self.titleColor = titleColor; self.action = action
    }
    public var body: some View {
        if let action {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(tint.opacity(0.10)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColor.muted)
                }
            }
            Spacer()
            if let badgeText = UnreadBadgeFormatter.text(badgeCount) {
                Text(badgeText)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(IMColor.danger))
                    .accessibilityLabel("\(title)有\(badgeText)条未读")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
        .contentShape(Rectangle())
    }
}

// WDT_IOS1_FEATURES_ME_UI_20261111_END

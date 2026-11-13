// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecurityActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let value: String

    public init(symbol: String, title: String, subtitle: String, value: String) { self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.value = value }

    public var body: some View {
        HStack(spacing: 14) {
            SecurityIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(IMColor.muted.opacity(0.65))
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

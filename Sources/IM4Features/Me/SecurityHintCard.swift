// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecurityHintCard: View {
    let symbol: String
    let title: String
    let subtitle: String

    public init(symbol: String, title: String, subtitle: String) { self.symbol = symbol; self.title = title; self.subtitle = subtitle }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SecurityIcon(symbol: symbol, tint: IMColor.warning)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .im4PlainCard(radius: 22)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

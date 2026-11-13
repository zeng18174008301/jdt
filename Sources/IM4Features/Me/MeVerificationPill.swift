// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct VerificationPill: View {
    let symbol: String
    let title: String
    var color: Color = IMColor.success

    public init(symbol: String, title: String, color: Color = IMColor.success) {
        self.symbol = symbol; self.title = title; self.color = color
    }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.11)))
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

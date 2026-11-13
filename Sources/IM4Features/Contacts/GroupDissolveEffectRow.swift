// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct GroupDissolveEffectRow: View {
    let symbol: String
    let text: String

    public init(symbol: String, text: String) { self.symbol = symbol; self.text = text }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.danger)
                .frame(width: 30, height: 30)
                .background(Circle().fill(IMColor.danger.opacity(0.10)))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

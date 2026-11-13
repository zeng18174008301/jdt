// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecurityIcon: View {
    let symbol: String
    var tint: Color = IMColor.brand

    public init(symbol: String, tint: Color = IMColor.brand) { self.symbol = symbol; self.tint = tint }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Circle().fill(tint.opacity(0.10)))
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

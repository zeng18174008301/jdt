// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct GroupSheetActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = IMColor.brand
    let action: () -> Void

    public init(title: String, symbol: String, tint: Color = IMColor.brand, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.tint = tint; self.action = action }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

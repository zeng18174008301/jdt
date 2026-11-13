// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct PhoneBindingInfoTile: View {
    let title: String
    let value: String

    public init(title: String, value: String) { self.title = title; self.value = value }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
            Text(value)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(IMColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(im4Hex: 0xF6F8FE))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line.opacity(0.82), lineWidth: 1))
        )
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

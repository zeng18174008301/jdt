// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct AboutInfoRow: View {
    let title: String
    let value: String

    public init(title: String, value: String) { self.title = title; self.value = value }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IMColor.muted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.62))
        )
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

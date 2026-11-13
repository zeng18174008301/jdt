// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct GroupMemberStat: View {
    let value: String
    let label: String

    public init(value: String, label: String) { self.value = value; self.label = label }

    public var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.06)))
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

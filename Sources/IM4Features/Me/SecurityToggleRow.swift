// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecurityToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    public init(title: String, subtitle: String, isOn: Binding<Bool>) { self.title = title; self.subtitle = subtitle; _isOn = isOn }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
        }
        .tint(IMColor.brand)
        .padding(.vertical, 11)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

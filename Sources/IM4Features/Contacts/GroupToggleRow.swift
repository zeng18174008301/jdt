// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct GroupToggleRow: View {
    let title: String
    let subtitle: String
    var isEnabled: Bool = true
    @Binding var isOn: Bool

    public init(title: String, subtitle: String, isEnabled: Bool = true, isOn: Binding<Bool>) { self.title = title; self.subtitle = subtitle; self.isEnabled = isEnabled; _isOn = isOn }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(IMColor.brand)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 12)
        .opacity(isEnabled ? 1 : 0.62)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

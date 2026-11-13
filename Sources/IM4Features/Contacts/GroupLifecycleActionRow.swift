// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct GroupLifecycleActionRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    public init(symbol: String, title: String, action: @escaping () -> Void) { self.symbol = symbol; self.title = title; self.action = action }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(IMColor.danger.opacity(0.10)))
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

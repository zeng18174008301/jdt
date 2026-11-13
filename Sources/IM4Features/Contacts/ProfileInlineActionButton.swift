// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct ProfileInlineActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var isDestructive = false
    let action: () -> Void

    public init(title: String,
                symbol: String,
                tint: Color,
                isDestructive: Bool = false,
                action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.tint = tint; self.isDestructive = isDestructive; self.action = action }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(isDestructive ? IMColor.danger : IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isDestructive ? IMColor.danger.opacity(0.06) : IMColor.page.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(isDestructive ? 0.16 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

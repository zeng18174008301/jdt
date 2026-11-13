// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct RealNameStatusHeroCard: View {
    let symbol: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let color: Color

    public init(symbol: String, eyebrow: String, title: String, subtitle: String, color: Color) { self.symbol = symbol; self.eyebrow = eyebrow; self.title = title; self.subtitle = subtitle; self.color = color }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    Circle()
                        .fill(LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: color.opacity(0.22), radius: 16, x: 0, y: 8)
                )
            VStack(spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(color.opacity(0.10)))
                Text(title)
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.90)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.97), color.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(color.opacity(0.12), lineWidth: 1))
        )
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

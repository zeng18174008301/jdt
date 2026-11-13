// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit

public enum IMColor {
    public static let brand = Color(hex: 0x5D6BFF)
    public static let peerName = Color(hex: 0x4F6F9F)
    public static let violet = Color(hex: 0x7C6BFF)
    public static let cyan = Color(hex: 0x50D2FF)
    public static let ink = Color(hex: 0x172033)
    public static let muted = Color(hex: 0x7A8397)
    public static let page = Color(hex: 0xF3F6FC)
    public static let card = Color.white
    public static let line = Color(hex: 0xE8ECF5)
    public static let danger = Color(hex: 0xFF5D73)
    public static let success = Color(hex: 0x23C48E)
    public static let warning = Color(hex: 0xFFB246)
}

func presenceBadgeColor(for status: String, offlineColor: Color = IMColor.muted) -> Color? {
    nil
}

public enum UnreadBadgeFormatter {
    public static let maximumVisibleCount = 99

    public static func text(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(min(count, maximumVisibleCount))"
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init?(hexString: String, alpha: Double = 1) {
        var normalized = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }
        guard normalized.count == 6, let value = UInt(normalized, radix: 16) else { return nil }
        self.init(hex: value, alpha: alpha)
    }
}

extension View {
    func glassCard(radius: CGFloat = 26) -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .shadow(color: Color(hex: 0x5D6BFF, alpha: 0.10), radius: 24, y: 12)
            )
    }

    func plainCard(radius: CGFloat = 22) -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(IMColor.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(IMColor.line, lineWidth: 1)
                    )
            )
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END

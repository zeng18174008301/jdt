// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecurityRequirementLine: View {
    let title: String
    let passed: Bool

    public init(title: String, passed: Bool) { self.title = title; self.passed = passed }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(passed ? IMColor.success : IMColor.muted.opacity(0.55))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(passed ? IMColor.ink : IMColor.muted)
        }
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

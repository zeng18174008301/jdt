// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct ProfileEditSheetSurface<Content: View>: View {
    @ViewBuilder var content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            content
                .padding(18)
        }
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white.opacity(0.92))
                .shadow(color: IMColor.brand.opacity(0.16), radius: 28, y: 14)
        )
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

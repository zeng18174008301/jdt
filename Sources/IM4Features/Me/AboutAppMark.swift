// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct AboutAppMark: View {
    public init() {  }

    public var body: some View {
        Image("LoginLogo")
            .resizable()
            .scaledToFill()
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: IMColor.brand.opacity(0.18), radius: 12, y: 6)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

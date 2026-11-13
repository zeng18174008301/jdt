// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecuritySectionTitle: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(IMColor.muted)
            .padding(.horizontal, 4)
            .padding(.top, 0)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

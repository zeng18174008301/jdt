// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct SecurityDivider: View {
    public init() {  }

    public var body: some View {
        Rectangle()
            .fill(IMColor.line)
            .frame(height: 1)
            .padding(.leading, 50)
    }
}
// WDT_IOS1_FEATURES_PURE_CONTROLS_20261111_END

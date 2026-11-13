// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ForcedAuthFlowContent<Flow: View>: View {
    let onClose: () -> Void
    let flow: () -> Flow

    public init(onClose: @escaping () -> Void, @ViewBuilder flow: @escaping () -> Flow) {
        self.onClose = onClose
        self.flow = flow
    }

    public var body: some View {
        NavigationStackCompat {
            flow()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", action: onClose)
                            .font(.system(size: 15, weight: .bold))
                    }
                }
        }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4DesignSystem

@MainActor
func dismissAuthFormKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
public struct AuthFlipLinkContent: View {
    let text: String
    let accent: String
    let identifier: String?
    let action: () -> Void
    public init(text: String, accent: String, identifier: String? = nil, action: @escaping () -> Void) {
        self.text = text; self.accent = accent; self.identifier = identifier; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text).foregroundStyle(IMColor.muted)
                Text(accent).foregroundStyle(IMColor.brand)
            }
            .font(.system(size: 13.5, weight: .bold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .modifier(AuthLinkIdentifier(identifier: identifier))
    }
}
private struct AuthLinkIdentifier: ViewModifier {
    let identifier: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

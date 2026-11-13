// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthRegistrationSubmissionContent: View {
    let message: String?
    let title: String
    let disabled: Bool
    let isLoading: Bool
    let onSubmit: () -> Void
    public init(message: String?, title: String, disabled: Bool, isLoading: Bool, onSubmit: @escaping () -> Void) {
        self.message = message; self.title = title; self.disabled = disabled; self.isLoading = isLoading; self.onSubmit = onSubmit
    }
    public var body: some View {
        if let message {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.brand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("auth_registration_resolution_message")
        }
        PrimaryButton(title: title, systemImage: "checkmark", disabled: disabled, isLoading: isLoading, action: onSubmit)
            .accessibilityIdentifier("auth_register_submit_button")
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

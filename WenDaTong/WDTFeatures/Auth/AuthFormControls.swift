import SwiftUI
import IM4Features

typealias AuthInputField = IM4Features.AuthInputField
typealias AuthInputFilter = IM4Features.AuthInputFilter
typealias AuthFormInputStyle = IM4Features.AuthFormInputStyle
typealias AuthFormInput<Field: Hashable> = IM4Features.AuthFormInput<Field>
typealias FlipOpacity = IM4Features.FlipOpacity
typealias ScrollContentHeightKey = IM4Features.ScrollContentHeightKey
typealias ScrollOffsetKey = IM4Features.ScrollOffsetKey
typealias LoginContentHeightKey = IM4Features.LoginContentHeightKey

#if DEBUG
private func registrationEntryCodeDebugSummary(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let format = RegistrationFlowPolicy.normalizedEntryCode(rawValue) == nil
        ? (trimmed.isEmpty ? "empty" : "invalid")
        : "supported"
    return "present=\(!trimmed.isEmpty) length=\(trimmed.count) format=\(format)"
}
#endif

func isCompleteAuthMainlandPhone(_ value: String) -> Bool {
    AuthInputFilter.mainlandPhone.apply(to: value).count == 11
}

struct RememberLoginCredentialsRow: View {
    let presentationStore: RememberLoginPresentationStore
    let onChange: (Bool) -> Void
    var body: some View {
        presentationStore.observe { isOn in
            RememberLoginCredentialsRowContent(isOn: isOn) {
                onChange(!presentationStore.isEnabled)
            }
        }
    }
}

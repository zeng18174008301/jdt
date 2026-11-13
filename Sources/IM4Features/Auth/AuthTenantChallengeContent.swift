// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthTenantChallengeContent: View {
    @Binding var enterpriseCode: String
    let isFocused: FocusState<Bool>.Binding
    let identifier: String
    let errorMessage: String?
    let normalizedCodeIsEmpty: Bool
    let isSubmitting: Bool
    let onNormalizedInputChange: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    public init(enterpriseCode: Binding<String>, isFocused: FocusState<Bool>.Binding, identifier: String, errorMessage: String?,
                normalizedCodeIsEmpty: Bool, isSubmitting: Bool, onNormalizedInputChange: @escaping () -> Void,
                onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _enterpriseCode = enterpriseCode; self.isFocused = isFocused; self.identifier = identifier; self.errorMessage = errorMessage
        self.normalizedCodeIsEmpty = normalizedCodeIsEmpty; self.isSubmitting = isSubmitting
        self.onNormalizedInputChange = onNormalizedInputChange; self.onSubmit = onSubmit; self.onCancel = onCancel
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("确认企业")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("请输入企业码，以确认要登录的企业。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.top, 8)

            if !identifier.isEmpty {
                Text("当前账号 \(identifier)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 14)
                    .accessibilityIdentifier("auth_tenant_challenge_identifier")
            }

            TextField("请输入企业编码或邀请码", text: $enterpriseCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(.system(size: 16, weight: .semibold))
                .im4ImReadableInputText()
                .focused(isFocused)
                .im4OnChangeCompat(of: enterpriseCode) { _, value in
                    let filtered = AuthInputFilter.entryCode().apply(to: value)
                    if filtered != value {
                        enterpriseCode = filtered
                    } else {
                        onNormalizedInputChange()
                    }
                }
                .submitLabel(.continue)
                .onSubmit(onSubmit)
                .padding(.horizontal, 15)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(im4Hex: 0xF4F6FB))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                )
                .accessibilityIdentifier("auth_tenant_challenge_code_field")
                .padding(.top, 22)

            if let message = errorMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.danger)
                    .padding(.top, 10)
                    .accessibilityIdentifier("auth_tenant_challenge_error")
            }

            PrimaryButton(
                title: isSubmitting ? "确认中..." : "继续登录",
                systemImage: "arrow.right",
                disabled: normalizedCodeIsEmpty || isSubmitting
            ) {
                onSubmit()
            }
            .accessibilityIdentifier("auth_tenant_challenge_continue_button")
            .padding(.top, 20)

            Button("返回登录", action: onCancel)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(IMColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityIdentifier("auth_tenant_challenge_cancel_button")
        }
        .padding(20)
        .authGlass()
        .onAppear { isFocused.wrappedValue = true }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isFocused.wrappedValue {
                    Spacer()
                    Button("收起") {
                        isFocused.wrappedValue = false
                        dismissAuthFormKeyboard()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

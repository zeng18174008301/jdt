// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthEnterpriseEntryContent: View {
    @Binding var enterpriseCode: String
    let isFocused: FocusState<Bool>.Binding
    let normalizedCodeIsEmpty: Bool
    let isResolving: Bool
    let errorMessage: String?
    let onResolve: () -> Void
    public init(enterpriseCode: Binding<String>, isFocused: FocusState<Bool>.Binding, normalizedCodeIsEmpty: Bool,
                isResolving: Bool, errorMessage: String?, onResolve: @escaping () -> Void) {
        _enterpriseCode = enterpriseCode; self.isFocused = isFocused; self.normalizedCodeIsEmpty = normalizedCodeIsEmpty
        self.isResolving = isResolving; self.errorMessage = errorMessage; self.onResolve = onResolve
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("先选择企业")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("手动输入企业编码或邀请码，验证后继续登录或注册。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.top, 8)

            TextField("请输入企业编码或邀请码", text: $enterpriseCode)
                .textInputAutocapitalization(.never) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .semibold))
                .im4ImReadableInputText()
                .focused(isFocused)
                .submitLabel(.continue)
                .onSubmit(onResolve)
                .padding(.horizontal, 15)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(im4Hex: 0xF4F6FB))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                )
                .accessibilityIdentifier("auth_enterprise_code_field")
                .padding(.top, 22)

            if let message = errorMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.danger)
                    .padding(.top, 10)
                    .accessibilityIdentifier("auth_enterprise_context_error")
            }

            PrimaryButton(
                title: isResolving ? "验证中..." : "继续",
                systemImage: "arrow.right",
                disabled: normalizedCodeIsEmpty || isResolving
            ) {
                onResolve()
            }
            .accessibilityIdentifier("auth_enterprise_continue_button")
            .padding(.top, 20)

            Text("企业编码或邀请码仅用于建立当前 App 与设备的企业登录上下文。")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.top, 14)
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

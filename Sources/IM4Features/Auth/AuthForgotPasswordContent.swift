// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthForgotPasswordContent: View {
    @Binding var account: String
    @Binding var code: String
    @Binding var newPassword: String
    let focusedField: FocusState<AuthInputField?>.Binding
    let isSendingCode: Bool
    let isResetting: Bool
    let captchaCooldown: Int
    let canReset: Bool
    let onSendCode: () -> Void
    let onReset: () -> Void
    let onBack: () -> Void

    public init(account: Binding<String>, code: Binding<String>, newPassword: Binding<String>,
                focusedField: FocusState<AuthInputField?>.Binding, isSendingCode: Bool,
                isResetting: Bool, captchaCooldown: Int, canReset: Bool,
                onSendCode: @escaping () -> Void, onReset: @escaping () -> Void, onBack: @escaping () -> Void) {
        _account = account
        _code = code
        _newPassword = newPassword
        self.focusedField = focusedField
        self.isSendingCode = isSendingCode
        self.isResetting = isResetting
        self.captchaCooldown = captchaCooldown
        self.canReset = canReset
        self.onSendCode = onSendCode
        self.onReset = onReset
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("找回密码")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(IMColor.ink)

            VStack(spacing: 14) {
                AuthFormInput(
                    title: "手机号",
                    placeholder: "请输入手机号",
                    text: $account,
                    field: .forgotAccount,
                    focusedField: focusedField,
                    textContentType: .username
                ) {
                    focusedField.wrappedValue = .forgotCode
                }
                HStack(alignment: .bottom, spacing: 10) {
                    AuthFormInput(
                        title: "验证码",
                        placeholder: "6 位验证码",
                        text: $code,
                        field: .forgotCode,
                        focusedField: focusedField,
                        keyboard: .numberPad,
                        textContentType: .oneTimeCode,
                        filter: .digits(maxLength: 6)
                    ) {
                        focusedField.wrappedValue = .forgotPassword
                    }
                    Button(forgotCaptchaTitle, action: onSendCode)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 74, height: 48)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(IMColor.brand))
                        .disabled(isSendingCode || captchaCooldown > 0)
                        .opacity(isSendingCode || captchaCooldown > 0 ? 0.62 : 1)
                }
                AuthFormInput(
                    title: "新密码",
                    placeholder: "设置新密码(8-20 位,含字母和数字)",
                    text: $newPassword,
                    field: .forgotPassword,
                    focusedField: focusedField,
                    secure: true,
                    keyboard: .asciiCapable,
                    textContentType: .newPassword,
                    submitLabel: .done,
                    keyboardActionTitle: "完成"
                ) {
                    focusedField.wrappedValue = nil
                }
            }
            .padding(.top, 18)

            PrimaryButton(title: isResetting ? "正在重置" : "重置密码", systemImage: "lock.rotation", disabled: !canReset || isResetting) {
                onReset()
            }
            .padding(.top, 28)   // 新密码↔重置 间距加大(≈2×)

            Spacer(minLength: 12)

            Button { onBack() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left").font(.system(size: 12, weight: .bold))
                    Text("返回登录")
                }
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 436, maxHeight: 436, alignment: .top)
        .authGlass()
    }

    private var forgotCaptchaTitle: String {
        if isSendingCode { return "发送中" }
        if captchaCooldown > 0 { return "\(captchaCooldown)s" }
        return "获取"
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

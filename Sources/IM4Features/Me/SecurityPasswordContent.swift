// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct SecurityPasswordContent: View {
    @Binding var currentPassword: String
    @Binding var newPassword: String
    @Binding var confirmPassword: String
    @Binding var verified: Bool
    let canSubmit: Bool
    let isSubmitting: Bool
    let onSubmit: () -> Void

    public init(currentPassword: Binding<String>, newPassword: Binding<String>, confirmPassword: Binding<String>,
                verified: Binding<Bool>, canSubmit: Bool, isSubmitting: Bool, onSubmit: @escaping () -> Void) {
        _currentPassword = currentPassword
        _newPassword = newPassword
        _confirmPassword = confirmPassword
        _verified = verified
        self.canSubmit = canSubmit
        self.isSubmitting = isSubmitting
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "key.fill", title: "修改密码", subtitle: "修改后新密码将在下次登录时生效。")

                    VStack(spacing: 14) {
                        FormInput(title: "当前密码", placeholder: "请输入当前密码", text: $currentPassword, secure: true, keyboard: .asciiCapable, textContentType: .password)
                        FormInput(title: "新密码", placeholder: "设置 8-20 位新密码", text: $newPassword, secure: true, keyboard: .asciiCapable, textContentType: .newPassword)
                        FormInput(title: "确认新密码", placeholder: "再次输入新密码", text: $confirmPassword, secure: true, keyboard: .asciiCapable, textContentType: .newPassword)
                        SecurityPasswordRequirementHint(password: newPassword, confirmPassword: confirmPassword)
                        SliderVerification(verified: $verified)
                        PrimaryButton(title: isSubmitting ? "保存中..." : "保存密码", systemImage: "checkmark.shield.fill", disabled: !canSubmit || isSubmitting) {
                            onSubmit()
                        }
                    }
                    .im4GlassCard(radius: 28)

                    SecurityHintCard(
                        symbol: "exclamationmark.shield.fill",
                        title: "安全提示",
                        subtitle: "修改密码不会影响已登录设备；如需管理在线端，请联系管理员处理。"
                    )
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
    }
}

private struct SecurityPasswordRequirementHint: View {
    let password: String
    let confirmPassword: String

    private var hasLength: Bool {
        password.count >= 8 && password.count <= 20
    }

    private var hasLetterAndNumber: Bool {
        password.rangeOfCharacter(from: .letters) != nil
            && password.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private var isMatched: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("密码格式要求")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(IMColor.ink)
            SecurityRequirementLine(title: "8-20 位字符", passed: hasLength)
            SecurityRequirementLine(title: "至少包含字母和数字", passed: hasLetterAndNumber)
            SecurityRequirementLine(title: "两次输入的密码一致", passed: isMatched)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IMColor.brand.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.brand.opacity(0.10), lineWidth: 1))
        )
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

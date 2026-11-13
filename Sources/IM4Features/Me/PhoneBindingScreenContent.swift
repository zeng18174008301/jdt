// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct PhoneBindingScreenContent<Form: View>: View {
    let isVerified: Bool
    let phoneDisplayText: String
    let form: Form

    public init(isVerified: Bool, phoneDisplayText: String, form: Form) {
        self.isVerified = isVerified
        self.phoneDisplayText = phoneDisplayText
        self.form = form
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(symbol: "iphone.gen3", title: "绑定手机号", subtitle: "")

                    PhoneBindingStatusPanel(
                        isVerified: isVerified,
                        phoneText: phoneDisplayText
                    )

                    if !isVerified {
                        form
                    }

                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
    }
}

public struct PhoneBindingFormContent: View {
    @Binding var phone: String
    @Binding var code: String
    let phoneIsValid: Bool
    let isSendingCode: Bool
    let codeCooldown: Int
    let phoneBindingCaptchaTitle: String
    let canSubmit: Bool
    let isSubmitting: Bool
    let onPhoneChange: (String) -> Void
    let onSendCode: () -> Void
    let onSubmit: () -> Void

    public init(phone: Binding<String>, code: Binding<String>, phoneIsValid: Bool,
                isSendingCode: Bool, codeCooldown: Int, phoneBindingCaptchaTitle: String, canSubmit: Bool,
                isSubmitting: Bool, onPhoneChange: @escaping (String) -> Void,
                onSendCode: @escaping () -> Void, onSubmit: @escaping () -> Void) {
        _phone = phone
        _code = code
        self.phoneIsValid = phoneIsValid
        self.isSendingCode = isSendingCode
        self.codeCooldown = codeCooldown
        self.phoneBindingCaptchaTitle = phoneBindingCaptchaTitle
        self.canSubmit = canSubmit
        self.isSubmitting = isSubmitting
        self.onPhoneChange = onPhoneChange
        self.onSendCode = onSendCode
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("绑定信息")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)

            FormInput(title: "手机号", placeholder: "请输入手机号", text: $phone, keyboard: .phonePad)
                .im4OnChangeCompat(of: phone) { _, newValue in
                    onPhoneChange(newValue)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text("验证码")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.muted)
                HStack(spacing: 10) {
                    TextField("请输入验证码", text: $code)
                        .font(.system(size: 16, weight: .bold))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                        .im4ImReadableInputText()
                        .frame(height: 48)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.92))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                        )
                    Button {
                        onSendCode()
                    } label: {
                        Text(phoneBindingCaptchaTitle)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 104, height: 48)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!phoneIsValid || isSendingCode || codeCooldown > 0)
                    .opacity(phoneIsValid ? (isSendingCode || codeCooldown > 0 ? 0.62 : 1) : 0.45)
                }
            }

            PrimaryButton(title: isSubmitting ? "绑定中..." : "确认绑定", systemImage: "checkmark.shield.fill", disabled: !canSubmit) {
                onSubmit()
            }
        }
        .im4GlassCard(radius: 28)
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct AuthRegisterFaceContent<Mode: Identifiable & Equatable & RawRepresentable, Branding: View, PasswordHint: View, Legal: View, Submission: View>: View where Mode.RawValue == String {
    @Binding var regMode: Mode
    @Binding var rPhone: String
    @Binding var rCode: String
    @Binding var rAccount: String
    @Binding var rPassword: String
    @Binding var rConfirm: String
    @Binding var enterpriseCode: String
    @State private var scrollContentH: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    let modes: [Mode]
    let phoneMode: Mode
    let focusedField: FocusState<AuthInputField?>.Binding
    let phoneAuthEnabled: Bool
    let enterpriseCodeFirst: Bool
    let enterpriseCodePlaceholder: String
    let entryCodeRequirementText: String
    let entryCodeRequirementEmphasized: Bool
    let isSendingRegisterCaptcha: Bool
    let registerCaptchaCooldown: Int
    let registerLegalShake: Int
    let branding: () -> Branding
    let passwordHint: () -> PasswordHint
    let legal: () -> Legal
    let submission: () -> Submission
    let onModeChange: () -> Void
    let onSendCaptcha: () -> Void
    let onLogin: () -> Void
    public init(mode: Binding<Mode>, modes: [Mode], phoneMode: Mode, phone: Binding<String>, code: Binding<String>,
                account: Binding<String>, password: Binding<String>, confirmation: Binding<String>, enterpriseCode: Binding<String>,
                focusedField: FocusState<AuthInputField?>.Binding, phoneAuthEnabled: Bool, enterpriseCodeFirst: Bool,
                enterpriseCodePlaceholder: String, entryCodeRequirementText: String, entryCodeRequirementEmphasized: Bool,
                isSendingCaptcha: Bool, captchaCooldown: Int, legalShake: Int,
                @ViewBuilder branding: @escaping () -> Branding, @ViewBuilder passwordHint: @escaping () -> PasswordHint,
                @ViewBuilder legal: @escaping () -> Legal, @ViewBuilder submission: @escaping () -> Submission,
                onModeChange: @escaping () -> Void, onSendCaptcha: @escaping () -> Void, onLogin: @escaping () -> Void) {
        _regMode = mode; _rPhone = phone; _rCode = code; _rAccount = account; _rPassword = password
        _rConfirm = confirmation; _enterpriseCode = enterpriseCode; self.modes = modes; self.phoneMode = phoneMode
        self.focusedField = focusedField; self.phoneAuthEnabled = phoneAuthEnabled; self.enterpriseCodeFirst = enterpriseCodeFirst
        self.enterpriseCodePlaceholder = enterpriseCodePlaceholder; self.entryCodeRequirementText = entryCodeRequirementText
        self.entryCodeRequirementEmphasized = entryCodeRequirementEmphasized; self.isSendingRegisterCaptcha = isSendingCaptcha
        self.registerCaptchaCooldown = captchaCooldown; self.registerLegalShake = legalShake; self.branding = branding
        self.passwordHint = passwordHint; self.legal = legal; self.submission = submission
        self.onModeChange = onModeChange; self.onSendCaptcha = onSendCaptcha; self.onLogin = onLogin
    }
    private var activeRegisterIdentityField: AuthInputField { regMode == phoneMode ? .registerPhone : .registerAccount }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("注册账号")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(IMColor.ink)

            branding() // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110

            if phoneAuthEnabled { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                AuthModeSwitchContent(mode: $regMode, modes: modes, phoneMode: phoneMode, suffix: "注册") {
                    onModeChange()
                }
                .accessibilityIdentifier("auth_register_mode_switch")
                .padding(.top, 16)
            }

            GeometryReader { vp in
              ScrollViewReader { legalScrollProxy in
              ScrollView(showsIndicators: false) {
                VStack(spacing: 13) {
                    identityFields
                    passwordFields
                    if !rPassword.isEmpty || !rConfirm.isEmpty {
                        passwordHint()
                    }

                    VStack(spacing: 10) {
                        legal()
                        submission()
                        AuthFlipLinkContent(text: "已有账号?", accent: "去登录", identifier: "auth_switch_to_login_button", action: onLogin)
                    }
                    .padding(.top, 4)
                    .id("register_legal_consent_anchor")
                }
                .padding(.top, 14)
                .padding(.bottom, focusedField.wrappedValue == nil ? 18 : AuthFlipLayoutPolicy.focusedKeyboardBottomInset)
                .background(GeometryReader { c in
                    Color.clear
                        .preference(key: ScrollContentHeightKey.self, value: c.size.height)
                        .preference(key: ScrollOffsetKey.self, value: -c.frame(in: .named("regScroll")).minY)
                })
              }
              .authInteractiveKeyboardDismiss()
              .background(
                  Color.clear
                      .contentShape(Rectangle())
                      .onTapGesture {
                          focusedField.wrappedValue = nil
                          dismissAuthFormKeyboard()
                      }
              )
              .coordinateSpace(name: "regScroll")
              .onPreferenceChange(ScrollContentHeightKey.self) { scrollContentH = $0 }
              .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
              .overlay(alignment: .topTrailing) { scrollThumb(viewport: vp.size.height) }
              // “请先勾选协议”提示时,把底部协议勾选区滚进视口:
              // 长表单下注册按钮可见而协议区在屏外,用户会不知道提示指什么。
              .im4OnChangeCompat(of: registerLegalShake) { _, trigger in
                  guard trigger > 0 else { return }
                  withAnimation(.easeOut(duration: 0.28)) {
                      legalScrollProxy.scrollTo("register_legal_consent_anchor", anchor: .bottom)
                  }
              }
              }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var identityFields: some View {
                    if !enterpriseCodeFirst { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                        AuthFormInput(
                            title: "企业编码或邀请码",
                            placeholder: enterpriseCodePlaceholder,
                            text: $enterpriseCode,
                            field: .registerEnterprise,
                            focusedField: focusedField,
                            textContentType: .oneTimeCode, // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
                            style: .registrationPlain,
                            onSubmit: {
                                focusedField.wrappedValue = activeRegisterIdentityField
                            }
                        )
                        Text(entryCodeRequirementText)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(entryCodeRequirementEmphasized ? IMColor.danger : IMColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if regMode == phoneMode {
                        AuthFormInput(
                            title: "手机号",
                            placeholder: "请输入手机号",
                            text: $rPhone,
                            field: .registerPhone,
                            focusedField: focusedField,
                            keyboard: .numberPad,
                            textContentType: .telephoneNumber,
                            filter: .mainlandPhone,
                            style: .registrationPlain
                        ) {
                            focusedField.wrappedValue = .registerCode
                        }
                        HStack(alignment: .bottom, spacing: 10) {
                            AuthFormInput(
                                title: "验证码",
                                placeholder: "6 位验证码",
                                text: $rCode,
                                field: .registerCode,
                                focusedField: focusedField,
                                keyboard: .numberPad,
                                textContentType: .oneTimeCode,
                                filter: .digits(maxLength: 6),
                                style: .registrationPlain
                            ) {
                                focusedField.wrappedValue = .registerPassword
                            }
                            Button(registerCaptchaButtonTitle, action: onSendCaptcha)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 78, height: 48)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand))
                            .disabled(isSendingRegisterCaptcha || registerCaptchaCooldown > 0)
                            .opacity(isSendingRegisterCaptcha || registerCaptchaCooldown > 0 ? 0.72 : 1)
                        }
                    } else {
                        AuthFormInput(
                            title: "账号",
                            placeholder: "账号",
                            text: $rAccount,
                            field: .registerAccount,
                            focusedField: focusedField,
                            keyboard: .asciiCapable,
                            textContentType: .username,
                            filter: .accountUsername,
                            style: .registrationPlain
                        ) {
                            focusedField.wrappedValue = .registerPassword
                        }
                    }
    }

    @ViewBuilder private var passwordFields: some View {
                    AuthFormInput(
                        title: "密码",
                        placeholder: "8-20 位数字和字母",
                        text: $rPassword,
                        field: .registerPassword,
                        focusedField: focusedField,
                        secure: true,
                        keyboard: .asciiCapable,
                        textContentType: .newPassword,
                        style: .registrationPlain
                    ) {
                        focusedField.wrappedValue = .registerConfirm
                    }
                    AuthFormInput(
                        title: "确认密码",
                        placeholder: "确认密码",
                        text: $rConfirm,
                        field: .registerConfirm,
                        focusedField: focusedField,
                        secure: true,
                        keyboard: .asciiCapable,
                        textContentType: .newPassword,
                        submitLabel: .done,
                        keyboardActionTitle: "完成",
                        style: .registrationPlain
                    ) {
                        focusedField.wrappedValue = nil
                    }
    }

    private var registerCaptchaButtonTitle: String {
        if isSendingRegisterCaptcha { return "发送中" }
        if registerCaptchaCooldown > 0 { return "\(registerCaptchaCooldown)s" }
        return "获取"
    }

    // 细品牌色自定义滚动条(内缩、不贴边)
    @ViewBuilder
    private func scrollThumb(viewport: CGFloat) -> some View {
        if viewport > 0, scrollContentH > viewport + 2 {
            let trackH = viewport - 10
            let thumbH = max(28, trackH * (viewport / scrollContentH))
            let maxOff = max(1, scrollContentH - viewport)
            let y = min(max(scrollOffset, 0), maxOff) / maxOff * (trackH - thumbH)
            Capsule()
                .fill(IMColor.brand.opacity(0.42))
                .frame(width: 3.5, height: thumbH)
                .padding(.trailing, 5)
                .offset(y: y + 5)
                .allowsHitTesting(false)
        }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

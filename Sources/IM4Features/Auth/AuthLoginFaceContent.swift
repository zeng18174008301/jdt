// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4DesignSystem

public struct AuthLoginFaceContent<Mode: Identifiable & Equatable & RawRepresentable, Branding: View, Remember: View, Legal: View>: View where Mode.RawValue == String {
    @Binding var loginMode: Mode
    @Binding var phone: String
    @Binding var account: String
    @Binding var password: String
    @Binding var loginContentHeight: CGFloat
    let modes: [Mode]
    let phoneMode: Mode
    let focusedField: FocusState<AuthInputField?>.Binding
    let phoneAuthEnabled: Bool
    let registrationEnabled: Bool
    let isLoading: Bool
    let branding: () -> Branding
    let remember: () -> Remember
    let legal: () -> Legal
    let onModeChange: () -> Void
    let onSubmit: () -> Void
    let onForgotPassword: () -> Void
    let onRegister: () -> Void
    public init(mode: Binding<Mode>, modes: [Mode], phoneMode: Mode, phone: Binding<String>, account: Binding<String>,
                password: Binding<String>, contentHeight: Binding<CGFloat>, focusedField: FocusState<AuthInputField?>.Binding,
                phoneAuthEnabled: Bool, registrationEnabled: Bool, isLoading: Bool,
                @ViewBuilder branding: @escaping () -> Branding, @ViewBuilder remember: @escaping () -> Remember,
                @ViewBuilder legal: @escaping () -> Legal, onModeChange: @escaping () -> Void,
                onSubmit: @escaping () -> Void, onForgotPassword: @escaping () -> Void, onRegister: @escaping () -> Void) {
        _loginMode = mode; _phone = phone; _account = account; _password = password; _loginContentHeight = contentHeight
        self.modes = modes; self.phoneMode = phoneMode; self.focusedField = focusedField; self.phoneAuthEnabled = phoneAuthEnabled
        self.registrationEnabled = registrationEnabled; self.isLoading = isLoading; self.branding = branding
        self.remember = remember; self.legal = legal; self.onModeChange = onModeChange; self.onSubmit = onSubmit
        self.onForgotPassword = onForgotPassword; self.onRegister = onRegister
    }
    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("欢迎回来")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(IMColor.ink)

                branding() // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110

                VStack(spacing: 14) {
                    if phoneAuthEnabled { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                        AuthModeSwitchContent(mode: $loginMode, modes: modes, phoneMode: phoneMode, suffix: "登录") {
                            onModeChange()
                        }
                        .accessibilityIdentifier("auth_login_mode_switch")
                    }
                    if loginMode == phoneMode {
                        AuthFormInput(
                            title: "手机号",
                            placeholder: "请输入手机号",
                            text: $phone,
                            field: .loginPhone,
                            focusedField: focusedField,
                            keyboard: .numberPad,
                            textContentType: .telephoneNumber,
                            filter: .mainlandPhone,
                            accessibilityIdentifier: "auth_login_phone_field"
                        ) {
                            focusedField.wrappedValue = .loginPassword
                        }
                    } else {
                        AuthFormInput(
                            title: "账号",
                            placeholder: "请输入账号",
                            text: $account,
                            field: .loginAccount,
                            focusedField: focusedField,
                            keyboard: .asciiCapable,
                            textContentType: .username,
                            accessibilityIdentifier: "auth_login_account_field"
                        ) {
                            focusedField.wrappedValue = .loginPassword
                        }
                    }
                    AuthFormInput(
                        title: "密码",
                        placeholder: "请输入密码",
                        text: $password,
                        field: .loginPassword,
                        focusedField: focusedField,
                        secure: true,
                        keyboard: .asciiCapable,
                        textContentType: .password,
                        submitLabel: .done,
                        keyboardActionTitle: "完成",
                        accessibilityIdentifier: "auth_login_password_field",
                        onSubmit: onSubmit
                    )
                }
                .padding(.top, 16)

                remember() // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110
                .padding(.top, 12)

                legal()
                .padding(.top, 10)

                PrimaryButton(title: isLoading ? "登录中..." : "登录", // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                              systemImage: loginMode == phoneMode ? "iphone" : "person.text.rectangle",
                              disabled: isLoading) { // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                    onSubmit()
                }
                .accessibilityIdentifier("auth_login_submit_button")
                .padding(.top, 14)

                Button("忘记密码") { onForgotPassword() } // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(IMColor.brand)   // 蓝色、可点击
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                if registrationEnabled { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                    AuthFlipLinkContent(text: "还没有账号?", accent: "注册", identifier: "auth_switch_to_register_button", action: onRegister)
                        .padding(.top, 10)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { content in
                Color.clear.preference(key: LoginContentHeightKey.self, value: content.size.height)
            })
            .padding(.bottom, focusedField.wrappedValue == nil ? 0 : AuthFlipLayoutPolicy.focusedKeyboardBottomInset)
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
        .frame(maxWidth: .infinity)
        .onPreferenceChange(LoginContentHeightKey.self) { loginContentHeight = $0 }
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

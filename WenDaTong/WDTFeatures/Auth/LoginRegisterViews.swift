import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

private struct UnifiedLoginView: View {
    @EnvironmentObject private var state: AppState
    @State private var mode: LoginMode
    @State private var phone = ""
    @State private var account = ""
    @State private var password = ""
    @State private var legalAccepted = AuthLegalConsentPolicy.isAcceptedByDefault
    @State private var legalShake = 0
    @State private var didLoadRememberedLoginCredentials = false
    @State private var rememberedLoginAutofillBinding: RememberedLoginAutofillBinding?
    @FocusState private var focusedField: AuthInputField?

    init(initialMode: LoginMode) {
        _mode = State(initialValue: initialMode)
    }

    private var activeIdentityField: AuthInputField {
        mode == .phone ? .loginPhone : .loginAccount
    }

    private func promptLegalAgreement() {
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(AuthLegalConsentPolicy.promptMessage)
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            legalShake += 1
        }
    }

    private func submitLogin() {
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: legalAccepted,
            onRejected: promptLegalAgreement
        ) else { return }
        if mode == .phone && !isCompleteAuthMainlandPhone(phone) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入 11 位中国大陆手机号；账号请切换到账号登录")
            focusedField = .loginPhone
            return
        }
        if mode == .account && account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入账号")
            focusedField = .loginAccount
            return
        }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入密码")
            focusedField = .loginPassword
            return
        }
        focusedField = nil
        let identifier = mode == .phone ? phone : account
        state.startLoginFlow(
            identifier: identifier,
            password: password,
            credentialMode: mode
        )
    }

    private func loadRememberedLoginCredentialsIfNeeded() {
        guard !didLoadRememberedLoginCredentials else { return }
        guard state.hasResolvedCurrentAppPolicyForAuthUI else { return }
        didLoadRememberedLoginCredentials = true
        guard let credentials = state.rememberedLoginCredentialsForAuthUI() else { return }
        let normalizedMode = LoginMode.normalized(
            credentials.mode,
            phoneAuthEnabled: state.isPhoneAuthEnabledForAuthUI
        )
        guard normalizedMode == credentials.mode else {
            state.clearRememberedLoginCredentials()
            return
        }
        rememberedLoginAutofillBinding = RememberedLoginAutofillBinding(credentials: credentials)
        mode = normalizedMode
        if credentials.mode == .phone {
            phone = credentials.identifier
        } else {
            account = credentials.identifier
        }
        password = credentials.password
    }

    private func invalidateRememberedLoginAutofillIfNeeded() {
        guard let binding = rememberedLoginAutofillBinding else { return }
        let identifier = mode == .phone ? phone : account
        guard !binding.stillMatches(mode: mode, identifier: identifier) else { return }
        password = ""
        rememberedLoginAutofillBinding = nil
    }

    private func normalizePhoneAuthMode() {
        mode = LoginMode.normalized(mode, phoneAuthEnabled: state.isPhoneAuthEnabledForAuthUI)
        guard !state.isPhoneAuthEnabledForAuthUI else { return }
        if focusedField == .loginPhone {
            focusedField = .loginAccount
        }
        guard state.hasResolvedCurrentAppPolicyForAuthUI else { return }
        if state.rememberedLoginCredentialsForAuthUI()?.mode == .phone {
            state.clearRememberedLoginCredentials()
        }
    }

    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
    var body: some View {
        // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
        state.authenticationPresentationStore.observeLoading { isLoading in // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            state.appPolicyPresentationStore.observe(\.authentication) { _ in loginContent(isLoading: isLoading) } // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        }
        // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END
    }

    private func loginContent(isLoading: Bool) -> some View { // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
        AuthPage(title: "企业即时协作", subtitle: "安全登录后进入当前企业空间。", showsBack: false, scrollToBottomTrigger: legalShake) {
            VStack(spacing: 20) {
                loginHero

                VStack(spacing: 16) {
                    if state.isPhoneAuthEnabledForAuthUI {
                        AuthModeSwitch(mode: $mode, suffix: "登录") {
                            if let focusedField, [.loginPhone, .loginAccount].contains(focusedField) {
                                self.focusedField = activeIdentityField
                            }
                        }
                        .accessibilityIdentifier("auth_login_mode_switch")
                    }

                    if mode == .phone {
                        AuthFormInput(
                            title: "手机号",
                            placeholder: "请输入手机号",
                            text: $phone,
                            field: .loginPhone,
                            focusedField: $focusedField,
                            keyboard: .numberPad,
                            textContentType: .telephoneNumber,
                            filter: .mainlandPhone
                        ) {
                            focusedField = .loginPassword
                        }
                    } else {
                        AuthFormInput(
                            title: "账号",
                            placeholder: "请输入账号",
                            text: $account,
                            field: .loginAccount,
                            focusedField: $focusedField,
                            keyboard: .asciiCapable,
                            textContentType: .username
                        ) {
                            focusedField = .loginPassword
                        }
                    }

                    AuthFormInput(
                        title: "密码",
                        placeholder: "请输入密码",
                        text: $password,
                        field: .loginPassword,
                        focusedField: $focusedField,
                        secure: true,
                        keyboard: .asciiCapable,
                        textContentType: .password,
                        submitLabel: .done,
                        keyboardActionTitle: "完成",
                        onSubmit: submitLogin
                    )

                    RememberLoginCredentialsRow(presentationStore: state.rememberLoginPresentationStore, onChange: state.setRememberLoginCredentialsEnabled) // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110

                    LegalDocumentLinksView(prefix: "我已阅读并同意", isAccepted: $legalAccepted, shakeTrigger: legalShake)

                    PrimaryButton(title: isLoading ? "登录中..." : "登录", systemImage: mode == .phone ? "iphone" : "person.text.rectangle", disabled: isLoading) { // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                        submitLogin()
                    }
                }
                .glassCard(radius: 30)

                VStack(spacing: 14) {
                    if state.isRegistrationEnabledForAuthUI {
                        Button {
                            state.setAuthScreen(state.isPhoneAuthEnabledForAuthUI ? .phoneRegister : .accountRegister) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.badge.plus")
                                Text("注册账号")
                            }
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.72))
                                    .overlay(Capsule().stroke(IMColor.brand.opacity(0.22), lineWidth: 1))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button("忘记密码") {
                        state.setAuthScreen(.forgotPassword) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            normalizePhoneAuthMode()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: state.hasResolvedCurrentAppPolicyForAuthUI) { _, _ in
            normalizePhoneAuthMode()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: state.isPhoneAuthEnabledForAuthUI) { _, _ in
            normalizePhoneAuthMode()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: mode) { _, _ in
            invalidateRememberedLoginAutofillIfNeeded()
        }
        .onChangeCompat(of: phone) { _, _ in
            invalidateRememberedLoginAutofillIfNeeded()
        }
        .onChangeCompat(of: account) { _, _ in
            invalidateRememberedLoginAutofillIfNeeded()
        }
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        .onDisappear {
            state.resetAccessDiagnosticsLogoTapSequence(entry: .loggedOutLoginLogo)
        }
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    private var loginHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                AuthBrandLockup(
                    logoSize: 72,
                    logoCornerRadius: 18,
                    titleSize: 25,
                    subtitleSize: 12,
                    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                    onLogoTap: {
                        state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
                    }
                    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                )
                Spacer()
            }
        }
        .padding(.top, 8)
    }

}

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
struct AuthModeSwitch: View {
    @Binding var mode: LoginMode
    let suffix: String
    let onChange: () -> Void
    var body: some View {
        AuthModeSwitchContent(mode: $mode, modes: LoginMode.allCases, phoneMode: .phone, suffix: suffix, onChange: onChange)
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
private struct UnifiedRegisterView: View {
    @EnvironmentObject private var state: AppState
    @State private var mode: LoginMode
    @State private var phone = ""
    @State private var code = ""
    @State private var account = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var enterpriseCode = ""
    @State private var verified = false
    @State private var captchaCooldown = 0
    @State private var isSendingCaptcha = false
    @State private var legalAccepted = AuthLegalConsentPolicy.isAcceptedByDefault
    @State private var legalShake = 0
    @FocusState private var focusedField: AuthInputField?

    private func canSubmit(_ confirmation: RegistrationConfirmationPresentationStore.Snapshot, isLoading: Bool? = nil) -> Bool { // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        let identityReady = mode == .phone
            ? isCompleteAuthMainlandPhone(phone)
            : isValidAuthAccountUsername(account)
        return state.isRegistrationEnabledForAuthUI
            && (!state.isEnterpriseCodeFirstForAuthUI || state.hasUsablePreAuthEnterpriseContext)
            && !(isLoading ?? state.isAuthLoading) // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            && !confirmation.isSubmissionBlocked(isAuthLoading: (isLoading ?? state.isAuthLoading)) // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            && verified
            && identityReady
            && entryCodeReady
            && PasswordRequirementHint.isValid(password: password, confirmPassword: confirmPassword)
    }

    private var entryCodeReady: Bool {
        return EnterpriseCodeAuthPresentationPolicy.registrationEntryCodeIsReady(
            enterpriseCodeFirst: state.isEnterpriseCodeFirstForAuthUI,
            registrationTenantCodeRequired: state.isRegistrationTenantCodeRequired,
            hasUsableContext: state.hasUsablePreAuthEnterpriseContext,
            normalizedEntryCode: RegistrationFlowPolicy.submittedEntryCode(enterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        )
    }

    private var enterpriseCodePlaceholder: String {
        state.isRegistrationTenantCodeRequired ? "请输入企业编码或邀请码" : "选填，企业编码或邀请码"
    }

    init(initialMode: LoginMode) {
        _mode = State(initialValue: initialMode)
    }

    private var activeIdentityField: AuthInputField {
        mode == .phone ? .registerPhone : .registerAccount
    }

    private func promptLegalAgreement() {
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(AuthLegalConsentPolicy.promptMessage)
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            legalShake += 1
        }
    }

    private func submitRegister() {
        guard !state.isRegistrationSubmissionBlocked else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(state.registrationConfirmationMessage)
            return
        }
        guard state.isRegistrationEnabledForAuthUI else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
            state.setAuthScreen(state.isPhoneAuthEnabledForAuthUI ? .phoneLogin : .accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return
        }
        if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
            state.setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return
        }
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: legalAccepted,
            onRejected: promptLegalAgreement
        ) else { return }
        if mode == .account && !isValidAuthAccountUsername(account) {
            // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册账号格式提示按文档统一
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("账号须为5–10位英文字母或数字。")
            // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            focusedField = .registerAccount
            return
        }
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册提交前按文档补齐密码与确认密码兜底提示
        if let failure = PasswordRequirementHint.validationFailure(password: password, confirmPassword: confirmPassword) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(failure.message)
            focusedField = failure.focus
            return
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        let normalizedEntryCode = state.isEnterpriseCodeFirstForAuthUI
            ? ""
            : RegistrationFlowPolicy.submittedEntryCode(enterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        if !entryCodeReady {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入企业编码或邀请码")
            focusedField = .registerEnterprise
            return
        }
        focusedField = nil
        if normalizedEntryCode.isEmpty {
            state.registerWithDefaultEnterprise(phone: phone, account: account, password: password, captchaCode: code)
        } else {
            state.registerAndEnterIM(phone: phone, account: account, password: password, enterpriseCode: normalizedEntryCode, captchaCode: code)
        }
    }

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.preAuthEnterpriseContextStore.observeBranding { _ in
            // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
            state.authenticationPresentationStore.observeLoading { isLoading in // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                state.appPolicyPresentationStore.observe(\.authentication) { _ in registerContent(isLoading: isLoading) } // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            }
            // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        }
    }

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END

    private func registerContent(isLoading: Bool) -> some View { // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        AuthPage(
            title: "注册账号",
            subtitle: state.isPhoneAuthEnabledForAuthUI
                ? "可使用手机号或账号注册；企业编码或邀请码按管理员策略填写。"
                : "使用账号注册；企业编码或邀请码按管理员策略填写。",
            scrollToBottomTrigger: legalShake
        ) {
            VStack(spacing: 16) {
                if state.isPhoneAuthEnabledForAuthUI {
                    AuthModeSwitch(mode: $mode, suffix: "注册") {
                        verified = false
                        if let focusedField, [.registerPhone, .registerCode, .registerAccount].contains(focusedField) {
                            self.focusedField = activeIdentityField
                        }
                    }
                    .accessibilityIdentifier("auth_register_mode_switch")
                }

                if mode == .phone {
                    AuthFormInput(
                        title: "手机号",
                        placeholder: "请输入手机号",
                        text: $phone,
                        field: .registerPhone,
                        focusedField: $focusedField,
                        keyboard: .numberPad,
                        textContentType: .telephoneNumber,
                        filter: .mainlandPhone
                    ) {
                        focusedField = .registerCode
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        AuthFormInput(
                            title: "验证码",
                            placeholder: "6 位验证码",
                            text: $code,
                            field: .registerCode,
                            focusedField: $focusedField,
                            keyboard: .numberPad,
                            textContentType: .oneTimeCode,
                            filter: .digits(maxLength: 6)
                        ) {
                            focusedField = .registerPassword
                        }
                        Button(registerCaptchaTitle) {
                            guard !isSendingCaptcha, captchaCooldown == 0 else { return }
                            isSendingCaptcha = true
                            Task {
                                let cooldown = await state.sendRegisterCaptcha(phone: phone, tenantCode: enterpriseCode)
                                await MainActor.run {
                                    isSendingCaptcha = false
                                    if let cooldown {
                                        captchaCooldown = cooldown
                                    }
                                }
                            }
                        }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 74, height: 48)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand))
                            .disabled(isSendingCaptcha || captchaCooldown > 0)
                            .opacity(isSendingCaptcha || captchaCooldown > 0 ? 0.72 : 1)
                    }
                } else {
                    AuthFormInput(
                        title: "账号",
                        placeholder: "5-10 位数字或英文字母",
                        text: $account,
                        field: .registerAccount,
                        focusedField: $focusedField,
                        keyboard: .asciiCapable,
                        textContentType: .username,
                        filter: .accountUsername
                    ) {
                        focusedField = .registerPassword
                    }
                }

                AuthFormInput(
                    title: "密码",
                    placeholder: "设置登录密码",
                    text: $password,
                    field: .registerPassword,
                    focusedField: $focusedField,
                    secure: true,
                    keyboard: .asciiCapable,
                    textContentType: .newPassword
                ) {
                    focusedField = .registerConfirm
                }
                AuthFormInput(
                    title: "确认密码",
                    placeholder: "再次输入密码",
                    text: $confirmPassword,
                    field: .registerConfirm,
                    focusedField: $focusedField,
                    secure: true,
                    keyboard: .asciiCapable,
                    textContentType: .newPassword
                ) {
                    focusedField = .registerEnterprise
                }
                PasswordRequirementHint(password: password, confirmPassword: confirmPassword)
                if !state.isEnterpriseCodeFirstForAuthUI {
                    AuthFormInput(
                        title: "企业编码或邀请码",
                        placeholder: enterpriseCodePlaceholder,
                        text: $enterpriseCode,
                        field: .registerEnterprise,
                        focusedField: $focusedField,
                        textContentType: .oneTimeCode,
                        submitLabel: .done,
                        keyboardActionTitle: "完成" // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
                    ) {
                        focusedField = nil
                    }
                    Text(state.registrationTenantCodeRequirementText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(state.isRegistrationTenantCodeRequirementEmphasized ? IMColor.danger : IMColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SliderVerification(verified: $verified)
                LegalDocumentLinksView(prefix: "我已阅读并同意", isAccepted: $legalAccepted, shakeTrigger: legalShake)
                // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_BEGIN
                state.registrationConfirmationStore.observe { confirmation in
                    if confirmation.resolution == .pending {
                        Text(confirmation.confirmationMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.brand)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("auth_registration_resolution_message")
                    }
                    PrimaryButton(title: confirmation.submitButtonTitle(isAuthLoading: isLoading), systemImage: "checkmark", disabled: !canSubmit(confirmation, isLoading: isLoading), isLoading: confirmation.isSubmissionBlocked(isAuthLoading: isLoading)) { // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                        submitRegister()
                    }
                }
                // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110_END
            }
            .glassCard(radius: 28)
        }
        .onAppear {
            if !state.isRegistrationEnabledForAuthUI {
                state.setAuthScreen(state.isPhoneAuthEnabledForAuthUI ? .phoneLogin : .accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            } else if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
                state.setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            }
            normalizePhoneAuthMode()
        }
        .onChangeCompat(of: enterpriseCode) { _, value in
            state.cancelRegistrationSessionRecovery(changedEntryCode: value)
        }
        .onChangeCompat(of: [phone, account, password, confirmPassword, code, String(describing: mode)]) { _, _ in
            state.registrationFormDidChange()
        }
        .onChangeCompat(of: state.isPhoneAuthEnabledForAuthUI) { _, _ in
            normalizePhoneAuthMode()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if captchaCooldown > 0 {
                captchaCooldown -= 1
            }
        }
    }

    private func normalizePhoneAuthMode() {
        mode = LoginMode.normalized(mode, phoneAuthEnabled: state.isPhoneAuthEnabledForAuthUI)
        guard !state.isPhoneAuthEnabledForAuthUI else { return }
        verified = false
        if let focusedField, [.registerPhone, .registerCode].contains(focusedField) {
            self.focusedField = .registerAccount
        }
    }

    private var registerCaptchaTitle: String {
        if isSendingCaptcha { return "发送中" }
        if captchaCooldown > 0 { return "\(captchaCooldown)s" }
        return "获取"
    }
}

struct PasswordRequirementHint: View {
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

    static func isValid(password: String, confirmPassword: String) -> Bool {
        password.count >= 8
            && password.count <= 20
            && password.rangeOfCharacter(from: .letters) != nil
            && password.rangeOfCharacter(from: .decimalDigits) != nil
            && password == confirmPassword
            && !confirmPassword.isEmpty
    }

    // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册本地校验文案与后端错误码文案合同保持一致
    static func validationFailure(password: String, confirmPassword: String) -> (message: String, focus: AuthInputField)? {
        guard password.count >= 8,
              password.count <= 20,
              password.rangeOfCharacter(from: .letters) != nil,
              password.rangeOfCharacter(from: .decimalDigits) != nil else {
            return ("密码须为8–20位，且包含字母和数字。", .registerPassword)
        }
        guard !confirmPassword.isEmpty else {
            return ("请输入确认密码", .registerConfirm)
        }
        guard password == confirmPassword else {
            return ("两次输入的密码不一致", .registerConfirm)
        }
        return nil
    }
    // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束

    var body: some View {
        AuthPasswordRequirementContent(hasLength: hasLength, hasLetterAndNumber: hasLetterAndNumber, isMatched: isMatched)
    }
}

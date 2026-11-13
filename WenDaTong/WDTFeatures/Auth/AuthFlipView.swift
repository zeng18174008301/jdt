import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

// 翻牌登录 / 注册:正面登录、背面注册;切换为 3D 翻转 + 卡片高度过渡。字段与流程与旧版一致(已去掉滑块验证)。
struct AuthFlipView: View {
    private typealias AuthenticationPolicy = AppPolicyPresentationStore.Authentication // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
    @EnvironmentObject private var state: AppState
    @State private var showRegister: Bool
    @State private var isFlipping = false
    @State private var flipCompletionTask: Task<Void, Never>?
    @State private var loginMode: LoginMode
    @State private var regMode: LoginMode
    let onPerformanceInteraction: () -> Void

    // 登录字段
    @State private var phone = ""
    @State private var account = ""
    @State private var password = ""
    @State private var loginLegalAccepted = AuthLegalConsentPolicy.isAcceptedByDefault
    @State private var loginLegalShake = 0
    @State private var loginContentHeight: CGFloat = 0
    @State private var didLoadRememberedLoginCredentials = false
    @State private var rememberedLoginAutofillBinding: RememberedLoginAutofillBinding?
    // 注册字段
    @State private var rPhone = ""
    @State private var rCode = ""
    @State private var rAccount = ""
    @State private var rPassword = ""
    @State private var rConfirm = ""
    @State private var enterpriseCode = ""
    @State private var registerCaptchaCooldown = 0
    @State private var isSendingRegisterCaptcha = false
    @State private var registerLegalAccepted = AuthLegalConsentPolicy.isAcceptedByDefault
    @State private var registerLegalShake = 0
    @FocusState private var focusedField: AuthInputField?

    init(initialRegister: Bool, initialMode: LoginMode = .phone, onPerformanceInteraction: @escaping () -> Void = {}) {
        _showRegister = State(initialValue: initialRegister)
        _loginMode = State(initialValue: initialMode)
        _regMode = State(initialValue: initialMode)
        self.onPerformanceInteraction = onPerformanceInteraction
    }

    private func registerCanSubmit(_ confirmation: RegistrationConfirmationPresentationStore.Snapshot, isLoading: Bool? = nil) -> Bool { // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        let identityReady = regMode == .phone
            ? isCompleteAuthMainlandPhone(rPhone)
            : isValidAuthAccountUsername(rAccount)
        return state.isRegistrationEnabledForAuthUI
            && (!state.isEnterpriseCodeFirstForAuthUI || state.hasUsablePreAuthEnterpriseContext)
            && !(isLoading ?? state.isAuthLoading) // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            && !confirmation.isSubmissionBlocked(isAuthLoading: (isLoading ?? state.isAuthLoading)) // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            && identityReady
            && registerEntryCodeReady
            && PasswordRequirementHint.isValid(password: rPassword, confirmPassword: rConfirm)
    }

    private var registerEntryCodeReady: Bool {
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

    private var activeLoginIdentityField: AuthInputField {
        loginMode == .phone ? .loginPhone : .loginAccount
    }

    private var activeRegisterIdentityField: AuthInputField {
        regMode == .phone ? .registerPhone : .registerAccount
    }

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
    var body: some View {
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_BEGIN
        state.appPolicyPresentationStore.observe(\.authentication) { policy in
            state.preAuthEnterpriseContextStore.observeBranding { branding in
                // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
                state.authenticationPresentationStore.observeLoading { isLoading in // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_BEGIN
                    state.authenticationPresentationStore.observeScreen { screen in
                        authContent(branding: branding, policy: policy, isLoading: isLoading, screen: screen) // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
                    }
                    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END
            }
        }
        // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110_END
    }

    private func authContent(branding: PreAuthEnterpriseContextStore.Branding?, policy: AuthenticationPolicy, isLoading: Bool, screen: AuthScreen) -> some View { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        AuthFlipCardContent(phoneAuthEnabled: policy.phoneAuthEnabled, showRegister: showRegister, isFlipping: isFlipping,
            loginContentHeight: loginContentHeight, login: { loginFace(branding: branding, policy: policy, isLoading: isLoading) },
            register: { registerFace(branding: branding, policy: policy, isLoading: isLoading) })
        .onChangeCompat(of: enterpriseCode) { _, value in
            state.cancelRegistrationSessionRecovery(changedEntryCode: value)
        }
        .onChangeCompat(of: [rPhone, rAccount, rPassword, rConfirm, rCode, String(describing: regMode)]) { _, _ in
            state.registrationFormDidChange()
        }
        .onChangeCompat(of: screen) { _, screen in // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            switch screen {
            case .phoneRegister, .accountRegister:
                regMode = screen == .phoneRegister ? .phone : .account
                flip(toRegister: true)
            case .welcome, .phoneLogin, .accountLogin:
                loginMode = screen == .phoneLogin ? .phone : .account
                flip(toRegister: false)
            default:
                break
            }
        }
        .onChangeCompat(of: focusedField) { _, newValue in
            if newValue != nil {
                onPerformanceInteraction()
            }
        }
        .onChangeCompat(of: loginMode) { _, _ in
            invalidateRememberedLoginAutofillIfNeeded()
        }
        .onChangeCompat(of: phone) { _, _ in
            invalidateRememberedLoginAutofillIfNeeded()
        }
        .onChangeCompat(of: account) { _, _ in
            invalidateRememberedLoginAutofillIfNeeded()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if registerCaptchaCooldown > 0 {
                registerCaptchaCooldown -= 1
            }
        }
        .onAppear {
            if showRegister && !policy.registrationEnabled { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                showRegister = false
            }
            normalizePhoneAuthModes()
            loadRememberedLoginCredentialsIfNeeded()
#if DEBUG
            applyLicenseQuotaRegistrationPrefillIfNeeded()
#endif
        }
        .onChangeCompat(of: policy.hasResolved) { _, _ in // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            normalizePhoneAuthModes()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: policy.phoneAuthEnabled) { _, _ in // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            normalizePhoneAuthModes()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: policy.registrationEnabled) { _, enabled in // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            if !enabled && showRegister {
                flip(toRegister: false)
            }
        }
        .onChangeCompat(of: state.hasUsablePreAuthEnterpriseContext) { _, usable in
            if policy.enterpriseCodeFirst && !usable { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                state.setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            }
        }
    }

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110: card framing is shared in AuthViews.swift.
    private func flip(toRegister: Bool) {
        if toRegister && !state.isRegistrationEnabledForAuthUI {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
            return
        }
        guard showRegister != toRegister else { return }
        if !toRegister { state.cancelRegistrationSessionRecovery() }
        onPerformanceInteraction()
        isFlipping = true
        flipCompletionTask?.cancel()
        withAnimation(.spring(response: 0.62, dampingFraction: 0.84)) {
            focusedField = nil
            showRegister = toRegister
        }
        flipCompletionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 720_000_000)
            if !Task.isCancelled {
                isFlipping = false
            }
        }
    }

    private func handleLoginModeChanged() {
        onPerformanceInteraction()
        if let focusedField, [.loginPhone, .loginAccount].contains(focusedField) {
            self.focusedField = activeLoginIdentityField
        }
    }

    private func handleRegisterModeChanged() {
        onPerformanceInteraction()
        if let focusedField, [.registerPhone, .registerCode, .registerAccount].contains(focusedField) {
            self.focusedField = activeRegisterIdentityField
        }
    }

#if DEBUG
    private func applyLicenseQuotaRegistrationPrefillIfNeeded() {
        guard state.isRegistrationEnabledForAuthUI,
              !state.isEnterpriseCodeFirstForAuthUI,
              let prefill = state.licenseQuotaRegistrationPrefill else { return }
        showRegister = true
        regMode = .account
        enterpriseCode = prefill.enterpriseCode
        rAccount = prefill.account
        rPassword = prefill.password
        rConfirm = prefill.password
        focusedField = nil
    }
#endif

    private func normalizePhoneAuthModes() {
        let phoneAuthEnabled = state.isPhoneAuthEnabledForAuthUI
        loginMode = LoginMode.normalized(loginMode, phoneAuthEnabled: phoneAuthEnabled)
        regMode = LoginMode.normalized(regMode, phoneAuthEnabled: phoneAuthEnabled)
        guard !phoneAuthEnabled else { return }
        if let focusedField, [.loginPhone, .registerPhone, .registerCode].contains(focusedField) {
            self.focusedField = showRegister ? .registerAccount : .loginAccount
        }
        guard state.hasResolvedCurrentAppPolicyForAuthUI else { return }
        if state.rememberedLoginCredentialsForAuthUI()?.mode == .phone {
            state.clearRememberedLoginCredentials()
        }
    }

    private func promptLoginLegalAgreement() {
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(AuthLegalConsentPolicy.promptMessage)
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            loginLegalShake += 1
        }
    }

    private func promptRegisterLegalAgreement() {
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(AuthLegalConsentPolicy.promptMessage)
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            registerLegalShake += 1
        }
    }

    private func submitLogin() {
        if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
            state.setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return
        }
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: loginLegalAccepted,
            onRejected: promptLoginLegalAgreement
        ) else { return }
        if loginMode == .phone && !isCompleteAuthMainlandPhone(phone) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入 11 位中国大陆手机号；账号请切换到账号登录")
            focusedField = .loginPhone
            return
        }
        if loginMode == .account && !isValidAuthAccountUsername(account) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("账号必须为 5-10 位数字或英文字母")
            focusedField = .loginAccount
            return
        }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入密码")
            focusedField = .loginPassword
            return
        }
        focusedField = nil
        let identifier = loginMode == .phone ? phone : account
        state.startLoginFlow(
            identifier: identifier,
            password: password,
            credentialMode: loginMode
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
        loginMode = normalizedMode
        if credentials.mode == .phone {
            phone = credentials.identifier
        } else {
            account = credentials.identifier
        }
        password = credentials.password
    }

    private func invalidateRememberedLoginAutofillIfNeeded() {
        guard let binding = rememberedLoginAutofillBinding else { return }
        let identifier = loginMode == .phone ? phone : account
        guard !binding.stillMatches(mode: loginMode, identifier: identifier) else { return }
        password = ""
        rememberedLoginAutofillBinding = nil
    }

    private func submitRegister() {
        guard !state.isRegistrationSubmissionBlocked else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(state.registrationConfirmationMessage)
            return
        }
        guard state.isRegistrationEnabledForAuthUI else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage)
            flip(toRegister: false)
            return
        }
        if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
            state.setAuthScreen(.enterpriseCode) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            return
        }
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: registerLegalAccepted,
            onRejected: promptRegisterLegalAgreement
        ) else { return }
        if regMode == .account && !isValidAuthAccountUsername(rAccount) {
            // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册账号格式提示按文档统一
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("账号须为5–10位英文字母或数字。")
            // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            focusedField = .registerAccount
            return
        }
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册提交前按文档补齐密码与确认密码兜底提示
        if let failure = PasswordRequirementHint.validationFailure(password: rPassword, confirmPassword: rConfirm) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast(failure.message)
            focusedField = failure.focus
            return
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        let normalizedEntryCode = state.isEnterpriseCodeFirstForAuthUI
            ? ""
            : RegistrationFlowPolicy.submittedEntryCode(enterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
        if !registerEntryCodeReady {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ state.setToast("请输入企业编码或邀请码")
            focusedField = .registerEnterprise
            return
        }
        focusedField = nil
        if normalizedEntryCode.isEmpty {
            state.registerWithDefaultEnterprise(phone: rPhone, account: rAccount, password: rPassword, captchaCode: rCode)
        } else {
            state.registerAndEnterIM(phone: rPhone, account: rAccount, password: rPassword, enterpriseCode: normalizedEntryCode, captchaCode: rCode)
        }
    }

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
    private func loginFace(branding: PreAuthEnterpriseContextStore.Branding?, policy: AuthenticationPolicy, isLoading: Bool) -> some View {
        AuthLoginFaceContent(mode: $loginMode, modes: LoginMode.allCases, phoneMode: .phone, phone: $phone, account: $account,
            password: $password, contentHeight: $loginContentHeight, focusedField: $focusedField,
            phoneAuthEnabled: policy.phoneAuthEnabled, registrationEnabled: policy.registrationEnabled, isLoading: isLoading,
            branding: { enterpriseContextBanner(branding: branding, enterpriseCodeFirst: policy.enterpriseCodeFirst) },
            remember: { RememberLoginCredentialsRow(presentationStore: state.rememberLoginPresentationStore, onChange: state.setRememberLoginCredentialsEnabled) },
            legal: { LegalDocumentLinksView(prefix: "我已阅读并同意", isAccepted: $loginLegalAccepted,
                shakeTrigger: loginLegalShake, consentAccessibilityIdentifier: "auth_login_legal_checkbox") },
            onModeChange: handleLoginModeChanged, onSubmit: submitLogin,
            onForgotPassword: { state.setAuthScreen(.forgotPassword) }, onRegister: { flip(toRegister: true) })
    }
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
    private func registerFace(branding: PreAuthEnterpriseContextStore.Branding?, policy: AuthenticationPolicy, isLoading: Bool) -> some View {
        AuthRegisterFaceContent(mode: $regMode, modes: LoginMode.allCases, phoneMode: .phone, phone: $rPhone, code: $rCode,
            account: $rAccount, password: $rPassword, confirmation: $rConfirm, enterpriseCode: $enterpriseCode,
            focusedField: $focusedField, phoneAuthEnabled: policy.phoneAuthEnabled, enterpriseCodeFirst: policy.enterpriseCodeFirst,
            enterpriseCodePlaceholder: enterpriseCodePlaceholder, entryCodeRequirementText: state.registrationTenantCodeRequirementText,
            entryCodeRequirementEmphasized: state.isRegistrationTenantCodeRequirementEmphasized,
            isSendingCaptcha: isSendingRegisterCaptcha, captchaCooldown: registerCaptchaCooldown, legalShake: registerLegalShake,
            branding: { enterpriseContextBanner(branding: branding, enterpriseCodeFirst: policy.enterpriseCodeFirst) },
            passwordHint: { PasswordRequirementHint(password: rPassword, confirmPassword: rConfirm) },
            legal: { LegalDocumentLinksView(prefix: "我已阅读并同意", isAccepted: $registerLegalAccepted,
                shakeTrigger: registerLegalShake, consentAccessibilityIdentifier: "auth_register_legal_checkbox") },
            submission: {
                state.registrationConfirmationStore.observe { confirmation in
                    AuthRegistrationSubmissionContent(message: confirmation.resolution == .pending ? confirmation.confirmationMessage : nil,
                        title: confirmation.submitButtonTitle(isAuthLoading: isLoading), disabled: !registerCanSubmit(confirmation, isLoading: isLoading),
                        isLoading: confirmation.isSubmissionBlocked(isAuthLoading: isLoading), onSubmit: submitRegister)
                }
            }, onModeChange: handleRegisterModeChanged, onSendCaptcha: sendRegisterCaptchaFromForm, onLogin: { flip(toRegister: false) })
    }

    private func sendRegisterCaptchaFromForm() {

                                guard !isSendingRegisterCaptcha, registerCaptchaCooldown == 0 else { return }
                                isSendingRegisterCaptcha = true
                                Task {
                                    let cooldown = await state.sendRegisterCaptcha(phone: rPhone, tenantCode: enterpriseCode)
                                    await MainActor.run {
                                        isSendingRegisterCaptcha = false
                                        if let cooldown {
                                            registerCaptchaCooldown = cooldown
                                        }
                                    }
                                }
    }
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
    @ViewBuilder
    private func enterpriseContextBanner(branding: PreAuthEnterpriseContextStore.Branding?, enterpriseCodeFirst: Bool) -> some View { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
        if enterpriseCodeFirst, state.hasUsablePreAuthEnterpriseContext, let branding { // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
            HStack(spacing: 10) {
                CachedRemoteImage(
                    urlString: branding.logoURL,
                    cacheKey: branding.logoCacheKey,
                    maxPixelSize: 96
                ) {
                    Image(systemName: "building.2.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(IMColor.brand)
                        .padding(6)
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(branding.name)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    Text("已绑定当前企业")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer(minLength: 0)
                Button("更换") {
                    state.clearPreAuthEnterpriseContext()
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .accessibilityIdentifier("auth_enterprise_context_change_button")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IMColor.brand.opacity(0.07)))
            .accessibilityIdentifier("auth_enterprise_context_banner")
            .padding(.top, 12)
        }
    }
    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END




}

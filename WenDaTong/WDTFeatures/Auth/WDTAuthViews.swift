import IM4Features
import Security
import SwiftUI
import UIKit
import WebKit

struct AuthRootView: View {
    @EnvironmentObject private var state: AppState

    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_BEGIN
    let animatesBackground: Bool

    init(animatesBackground: Bool = true) {
        self.animatesBackground = animatesBackground
    }

    var body: some View {
        state.authenticationPresentationStore.observeScreen { screen in rootContent(screen: screen) }
    }

    private func rootContent(screen: AuthScreen) -> some View {
        AuthRootContent(animatesBackground: animatesBackground, onLogoTap: {
            state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
        }, card: { cardArea(screen: screen) })
        .task {
            await state.refreshCurrentAppPolicyForAuthUI(force: true)
        }
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        .onDisappear {
            state.resetAccessDiagnosticsLogoTapSequence(entry: .loggedOutLoginLogo)
        }
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    @ViewBuilder private func cardArea(screen: AuthScreen) -> some View {
        ZStack(alignment: .top) {
            switch screen {
            case .enterpriseCode:
                EnterpriseCodeEntryView().compositingGroup().transition(.im4AuthArc(fromLeading: true))
            // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：普通登录同名多商户时进入临时企业码确认页
            case .tenantCodeChallenge:
                LoginTenantCodeChallengeView().compositingGroup().transition(.im4AuthArc(fromLeading: false))
            // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
            case .welcome, .phoneLogin, .accountLogin, .phoneRegister, .accountRegister:
                // One structural identity keeps the current registration fields when
                // a failed/pending response updates the auth route.
                AuthFlipView(
                    initialRegister: screen == .phoneRegister || screen == .accountRegister,
                    initialMode: screen == .phoneLogin || screen == .phoneRegister ? .phone : .account
                ) { }
                .compositingGroup()
                .transition(.im4AuthArc(fromLeading: true))
            case .forgotPassword:
                ForgotPasswordView().compositingGroup().transition(.im4AuthArc(fromLeading: false))
            case .workspaceSelection:
                LoginWorkspaceSelectionView().compositingGroup().transition(.im4AuthArc(fromLeading: false))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.48, dampingFraction: 0.92), value: screen)
    }

    // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110_END
}

struct SessionReauthenticationView: View {
    @EnvironmentObject private var state: AppState
    let presentationID: UUID // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
    @State private var identifier = ""
    @State private var password = ""
    @State private var enterpriseCode = ""
    @State private var submissionTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private typealias Field = AuthReauthenticationField

    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.sessionReauthenticationStore.observe({ $0 }) { snapshot in
            formContent(snapshot)
        }
    }

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
    private func formContent(_ snapshot: SessionReauthenticationStore.Snapshot) -> some View {
        let isSubmitting = submissionTask != nil || snapshot.isSubmitting
        return AuthReauthenticationContent(identifier: $identifier, password: $password, enterpriseCode: $enterpriseCode,
            focusedField: $focusedField, isSubmitting: isSubmitting, errorMessage: snapshot.errorMessage,
            onCancel: cancel, onSubmit: submit)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            password = ""
            state.cancelSessionReauthentication(presentationID: presentationID) // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
        }
    }
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
    private func submit() {
        guard submissionTask == nil, !state.sessionReauthenticationStore.snapshot.isSubmitting else { return } // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
        focusedField = nil
        submissionTask = Task { @MainActor in
            _ = await state.reauthenticateCurrentSession(
                identifier: identifier,
                password: password,
                enterpriseCode: enterpriseCode,
                presentationID: presentationID // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
            )
            guard !Task.isCancelled else { return }
            password = ""
            submissionTask = nil
        }
    }

    private func cancel() {
        submissionTask?.cancel()
        submissionTask = nil
        focusedField = nil
        password = ""
        state.cancelSessionReauthentication(presentationID: presentationID) // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110
    }
}

private struct EnterpriseCodeEntryView: View {
    @EnvironmentObject private var state: AppState
    @State private var enterpriseCode = ""
    @FocusState private var isFocused: Bool

    private var normalizedCode: String {
        RegistrationFlowPolicy.submittedEntryCode(enterpriseCode) // WDT_IOS1_REGISTRATION_CODE_PASSTHROUGH_20261113
    }

    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.preAuthEnterpriseContextStore.observeForm { form in
            state.appPolicyPresentationStore.observe(\.authentication.enterpriseCodeFirst) { _ in // WDT_IOS1_REFACTOR_APP_POLICY_OBSERVATION_20261110
                entryContent(form)
            }
        }
    }

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
    private func entryContent(_ form: PreAuthEnterpriseContextStore.Form) -> some View {
        AuthEnterpriseEntryContent(enterpriseCode: $enterpriseCode, isFocused: $isFocused, normalizedCodeIsEmpty: normalizedCode.isEmpty,
            isResolving: form.isResolving, errorMessage: form.errorMessage, onResolve: resolve)
        .onChangeCompat(of: state.isEnterpriseCodeFirstForAuthUI) { _, enabled in
            if !enabled { state.setAuthScreen(.accountLogin) } // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        }
    }
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
    // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110_END

    private func resolve() {
        let value = normalizedCode
        guard !value.isEmpty, !state.preAuthEnterpriseContextStore.form.isResolving else { return } // WDT_IOS1_REFACTOR_PREAUTH_ENTERPRISE_OBSERVATION_20261110
        isFocused = false
        Task { _ = await state.resolveEnterpriseContext(enterpriseCode: value) }
    }
}

// JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：登录挑战企业码确认页，不展示商户列表、不持久化密码
private struct LoginTenantCodeChallengeView: View {
    @EnvironmentObject private var state: AppState
    @State private var enterpriseCode = ""
    @FocusState private var isFocused: Bool

    private var normalizedCode: String {
        RegistrationFlowPolicy.normalizedEntryCode(enterpriseCode)?.normalizedValue ?? ""
    }

    // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.loginTenantCodeChallengeStore.observe { snapshot in
            // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_BEGIN
            state.authenticationPresentationStore.observeLoading { isLoading in challengeContent(snapshot, isLoading: isLoading) } // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
            // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110_END
        }
    }

// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
    private func challengeContent(_ snapshot: LoginTenantCodeChallengeStore.Snapshot, isLoading: Bool) -> some View {
        AuthTenantChallengeContent(enterpriseCode: $enterpriseCode, isFocused: $isFocused, identifier: snapshot.identifier,
            errorMessage: snapshot.errorMessage, normalizedCodeIsEmpty: normalizedCode.isEmpty,
            isSubmitting: snapshot.isSubmitting || isLoading, onNormalizedInputChange: { state.loginTenantCodeChallengeInputDidChange() },
            onSubmit: submit, onCancel: {

                isFocused = false
                dismissAuthKeyboard()
                enterpriseCode = ""
                state.cancelLoginTenantCodeChallenge()
            })
    }
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END
    // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_END

    private func submit() {
        let value = normalizedCode
        // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_BEGIN
        guard !value.isEmpty, !state.isAuthLoading,
              !state.loginTenantCodeChallengeStore.snapshot.isSubmitting else { return }
        // WDT_IOS1_REFACTOR_LOGIN_TENANT_CHALLENGE_OBSERVATION_20261110_END
        isFocused = false
        dismissAuthKeyboard()
        state.submitLoginTenantCodeChallenge(enterpriseCode: value)
    }
}
// JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束

typealias AuthBrandLockup = IM4Features.AuthBrandLockup

enum LoginMode: String, CaseIterable, Identifiable, Equatable {
    case phone = "手机号"
    case account = "账号"

    var id: String { rawValue }

    var storageValue: String {
        switch self {
        case .phone:
            return "phone"
        case .account:
            return "account"
        }
    }

    static func fromStorageValue(_ value: String?) -> LoginMode {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "phone":
            return .phone
        default:
            return .account
        }
    }

    static func normalized(_ mode: LoginMode, phoneAuthEnabled: Bool) -> LoginMode {
        phoneAuthEnabled ? mode : .account
    }
}

enum AuthLegalConsentPolicy {
    static let isAcceptedByDefault = true
    static let promptMessage = "请先勾选用户协议和隐私政策"

    static func authorize(isAccepted: Bool, onRejected: () -> Void) -> Bool {
        guard isAccepted else {
            onRejected()
            return false
        }
        return true
    }
}

@MainActor
func dismissAuthKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

typealias AuthFlipLayoutPolicy = IM4Features.AuthFlipLayoutPolicy



// WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_BEGIN
// WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_BEGIN
@MainActor
struct ForcedAppPolicyAuthPresentationModifier: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        let store = state.forcedAppPolicyAuthStore
        return PublisherSnapshotView(
            initialValue: store.snapshot.presentation,
            updates: store.updates(\.presentation)
        ) { _ in
            content
                .alert(item: forcedAppPolicyAuthPromptBinding) { requirement in
                    Alert(
                        title: Text(requirement.promptTitle),
                        message: Text(requirement.promptMessage),
                        dismissButton: .default(Text(requirement.actionTitle)) {
                            state.openForcedAppPolicyAuthDestination(requirement)
                        }
                    )
                }
                .fullScreenCover(item: forcedAppPolicyAuthDestinationBinding, onDismiss: {
                    state.forcedAppPolicyAuthDestinationDidDismiss()
                }) { requirement in
                    ForcedAppPolicyAuthFlowView(requirement: requirement)
                        .environmentObject(state)
                }
        }
    }

    private var forcedAppPolicyAuthPromptBinding: Binding<AppPolicyForcedAuthRequirement?> {
        Binding(
            get: { state.visibleForcedAppPolicyAuthPrompt },
            set: { state.updateVisibleForcedAppPolicyAuthPrompt($0) }
        )
    }

    private var forcedAppPolicyAuthDestinationBinding: Binding<AppPolicyForcedAuthRequirement?> {
        Binding(
            get: { state.visibleForcedAppPolicyAuthDestination },
            set: { state.updateVisibleForcedAppPolicyAuthDestination($0) }
        )
    }
}
// WDT_IOS1_REFACTOR_FORCED_AUTH_PRESENTATION_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110_END

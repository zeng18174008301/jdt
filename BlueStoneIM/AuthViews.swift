import Security
import SwiftUI
import UIKit
import WebKit

struct AuthRootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            AuthBackground()
            VStack(alignment: .leading, spacing: 0) {
                AuthBrandHeader()          // logo + 名称:切换动画时保持不动
                Color.clear.frame(height: 22)
                cardArea
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            await state.refreshCurrentAppPolicyForAuthUI(force: true)
        }
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        .onDisappear {
            state.resetAccessDiagnosticsLogoTapSequence(entry: .loggedOutLoginLogo)
        }
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    @ViewBuilder private var cardArea: some View {
        ZStack(alignment: .top) {
            switch state.authScreen {
            case .enterpriseCode:
                EnterpriseCodeEntryView().compositingGroup().transition(.arc(fromLeading: true))
            // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：普通登录同名多商户时进入临时企业码确认页
            case .tenantCodeChallenge:
                LoginTenantCodeChallengeView().compositingGroup().transition(.arc(fromLeading: false))
            // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
            case .welcome, .phoneLogin, .accountLogin, .phoneRegister, .accountRegister:
                // One structural identity keeps the current registration fields when
                // a failed/pending response updates the auth route.
                AuthFlipView(
                    initialRegister: state.authScreen == .phoneRegister || state.authScreen == .accountRegister,
                    initialMode: state.authScreen == .phoneLogin || state.authScreen == .phoneRegister ? .phone : .account
                ) { }
                .compositingGroup()
                .transition(.arc(fromLeading: true))
            case .forgotPassword:
                ForgotPasswordView().compositingGroup().transition(.arc(fromLeading: false))
            case .workspaceSelection:
                LoginWorkspaceSelectionView().compositingGroup().transition(.arc(fromLeading: false))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.48, dampingFraction: 0.92), value: state.authScreen)
    }

}

struct SessionReauthenticationView: View {
    @EnvironmentObject private var state: AppState
    @State private var identifier = ""
    @State private var password = ""
    @State private var enterpriseCode = ""
    @State private var submissionTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case identifier, password, enterpriseCode
    }

    private var isSubmitting: Bool {
        submissionTask != nil || state.isSessionReauthenticating
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("重新验证登录")
                            .font(.system(size: 24, weight: .bold))
                        Spacer()
                        Button("取消", action: cancel)
                            .accessibilityIdentifier("session_reauthentication_cancel")
                    }

                    Text("请使用当前账号和密码恢复连接。本机聊天数据会保留。")
                        .font(.subheadline)
                        .foregroundStyle(IMColor.muted)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当前账号")
                                .font(.subheadline.weight(.semibold))
                            TextField("账号或手机号", text: $identifier)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                                .focused($focusedField, equals: .identifier)
                                .accessibilityIdentifier("session_reauthentication_identifier")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("密码")
                                .font(.subheadline.weight(.semibold))
                            SecureField("请输入当前账号密码", text: $password)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .accessibilityIdentifier("session_reauthentication_password")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("企业码（可选）")
                                .font(.subheadline.weight(.semibold))
                            TextField("应用策略要求时请填写", text: $enterpriseCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .enterpriseCode)
                                .accessibilityIdentifier("session_reauthentication_enterprise_code")
                        }
                    }
                    .imReadableInputText()
                    .disabled(isSubmitting)
                    .plainCard(radius: 22)

                    if let error = state.sessionReauthenticationError, !error.isEmpty {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(IMColor.danger)
                            .accessibilityIdentifier("session_reauthentication_error")
                    }

                    Button(action: submit) {
                        HStack(spacing: 10) {
                            if isSubmitting {
                                ProgressView()
                            }
                            Text(isSubmitting ? "正在验证…" : "验证并恢复连接")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("session_reauthentication_submit")
                }
                .padding(22)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityAddTraits(.isModal)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            password = ""
            if state.isSessionReauthenticationPresented {
                state.cancelSessionReauthentication()
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        focusedField = nil
        submissionTask = Task { @MainActor in
            _ = await state.reauthenticateCurrentSession(
                identifier: identifier,
                password: password,
                enterpriseCode: enterpriseCode
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
        state.cancelSessionReauthentication()
    }
}

private struct EnterpriseCodeEntryView: View {
    @EnvironmentObject private var state: AppState
    @State private var enterpriseCode = ""
    @FocusState private var isFocused: Bool

    private var normalizedCode: String {
        RegistrationFlowPolicy.normalizedEntryCode(enterpriseCode)?.normalizedValue ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("先选择企业")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("手动输入企业编码或邀请码，验证后继续登录或注册。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.top, 8)

            TextField("请输入企业编码或邀请码", text: $enterpriseCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(.system(size: 16, weight: .semibold))
                .imReadableInputText()
                .focused($isFocused)
                .onChangeCompat(of: enterpriseCode) { _, value in
                    let filtered = AuthInputFilter.entryCode().apply(to: value)
                    if filtered != value { enterpriseCode = filtered }
                }
                .submitLabel(.continue)
                .onSubmit(resolve)
                .padding(.horizontal, 15)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: 0xF4F6FB))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                )
                .accessibilityIdentifier("auth_enterprise_code_field")
                .padding(.top, 22)

            if let message = state.enterpriseContextErrorMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.danger)
                    .padding(.top, 10)
                    .accessibilityIdentifier("auth_enterprise_context_error")
            }

            PrimaryButton(
                title: state.isResolvingEnterpriseContext ? "验证中..." : "继续",
                systemImage: "arrow.right",
                disabled: normalizedCode.isEmpty || state.isResolvingEnterpriseContext
            ) {
                resolve()
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
        .onAppear { isFocused = true }
        .onChangeCompat(of: state.isEnterpriseCodeFirstForAuthUI) { _, enabled in
            if !enabled { state.authScreen = .accountLogin }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isFocused {
                    Spacer()
                    Button("收起") {
                        isFocused = false
                        dismissAuthKeyboard()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }

    private func resolve() {
        let value = normalizedCode
        guard !value.isEmpty, !state.isResolvingEnterpriseContext else { return }
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

    private var isSubmitting: Bool {
        state.isSubmittingLoginTenantCodeChallenge || state.isAuthLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("确认企业")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text("请输入企业码，以确认要登录的企业。")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.top, 8)

            if !state.loginTenantCodeChallengeIdentifier.isEmpty {
                Text("当前账号 \(state.loginTenantCodeChallengeIdentifier)")
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
                .imReadableInputText()
                .focused($isFocused)
                .onChangeCompat(of: enterpriseCode) { _, value in
                    let filtered = AuthInputFilter.entryCode().apply(to: value)
                    if filtered != value {
                        enterpriseCode = filtered
                    } else {
                        state.loginTenantCodeChallengeInputDidChange()
                    }
                }
                .submitLabel(.continue)
                .onSubmit(submit)
                .padding(.horizontal, 15)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: 0xF4F6FB))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                )
                .accessibilityIdentifier("auth_tenant_challenge_code_field")
                .padding(.top, 22)

            if let message = state.loginTenantCodeChallengeErrorMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.danger)
                    .padding(.top, 10)
                    .accessibilityIdentifier("auth_tenant_challenge_error")
            }

            PrimaryButton(
                title: isSubmitting ? "确认中..." : "继续登录",
                systemImage: "arrow.right",
                disabled: normalizedCode.isEmpty || isSubmitting
            ) {
                submit()
            }
            .accessibilityIdentifier("auth_tenant_challenge_continue_button")
            .padding(.top, 20)

            Button("返回登录") {
                isFocused = false
                dismissAuthKeyboard()
                enterpriseCode = ""
                state.cancelLoginTenantCodeChallenge()
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(IMColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityIdentifier("auth_tenant_challenge_cancel_button")
        }
        .padding(20)
        .authGlass()
        .onAppear { isFocused = true }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isFocused {
                    Spacer()
                    Button("收起") {
                        isFocused = false
                        dismissAuthKeyboard()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }

    private func submit() {
        let value = normalizedCode
        guard !value.isEmpty, !isSubmitting else { return }
        isFocused = false
        dismissAuthKeyboard()
        state.submitLoginTenantCodeChallenge(enterpriseCode: value)
    }
}
// JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束

struct IOSSlideCaptchaVerificationOverlay: View {
    @EnvironmentObject private var state: AppState
    let challenge: RemoteSlideCaptchaChallenge

    @State private var dragX: CGFloat = 0
    @State private var startedAt = Date()
    @State private var points: [SlideCaptchaDragPoint] = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录安全验证")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("验证通过后才会继续校验账号和密码。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer(minLength: 0)
                    Button {
                        state.cancelSlideCaptcha()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(hex: 0xF3F5FA)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭滑动验证")
                }

                slideBody
            }
            .padding(18)
            .frame(maxWidth: 390)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 30, y: 16)
            )
            .padding(.horizontal, 20)
        }
    }

    private var slideBody: some View {
        GeometryReader { proxy in
            let naturalWidth = CGFloat(max(challenge.width, 240))
            let naturalHeight = CGFloat(max(challenge.height, 120))
            let displayWidth = min(proxy.size.width, naturalWidth)
            let scale = displayWidth / naturalWidth
            let displayHeight = naturalHeight * scale
            let pieceSize = CGFloat(max(challenge.pieceSize, 32))
            let naturalMax = max(1, naturalWidth - pieceSize)
            let pieceY = min(max(0, CGFloat(challenge.pieceY)), max(0, naturalHeight - pieceSize))
            VStack(spacing: 14) {
                ZStack(alignment: .topLeading) {
                    captchaImage(challenge.backgroundImage)
                        .frame(width: displayWidth, height: displayHeight)
                        .clipped()
                    captchaImage(challenge.pieceImage)
                        .frame(width: pieceSize * scale, height: pieceSize * scale)
                        .offset(x: dragX * scale, y: pieceY * scale)
                        .shadow(color: Color.black.opacity(0.28), radius: 8, y: 4)
                }
                .frame(width: displayWidth, height: displayHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(IMColor.line))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(hex: 0xEDF1FA))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(IMColor.brand.opacity(0.16))
                        .frame(width: max(44, dragX * scale + 44))
                    Text("按住滑块拖动到缺口位置")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                    Circle()
                        .fill(IMColor.brand)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.white)
                        )
                        .offset(x: min(max(0, dragX * scale), max(0, displayWidth - 44)))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let nextX = min(max(value.translation.width / max(scale, 0.01), 0), naturalMax)
                                    dragX = nextX
                                    recordPoint(y: value.location.y)
                                }
                                .onEnded { value in
                                    recordPoint(y: value.location.y, force: true)
                                    complete(durationMS: max(1, Int(Date().timeIntervalSince(startedAt) * 1000)))
                                }
                        )
                }
                .frame(width: displayWidth, height: 48)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .onAppear {
                startedAt = Date()
                points = []
                dragX = 0
            }
        }
        .frame(height: 236)
    }

    @ViewBuilder
    private func captchaImage(_ value: String) -> some View {
        if let image = UIImage.slideCaptchaDataURL(value) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0xEEF2F7))
                .overlay(
                    Text("图片加载失败")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                )
        }
    }

    private func recordPoint(y: CGFloat, force: Bool = false) {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        if !force, let last = points.last, elapsed - last.t < 60 { return }
        points.append(SlideCaptchaDragPoint(x: Double(dragX), y: Double(y), t: elapsed))
    }

    private func complete(durationMS: Int) {
        let ticket = SlideCaptchaTicket(
            ticket: "",
            randstr: "",
            challengeID: challenge.challengeID,
            lotNumber: "",
            captchaOutput: "",
            passToken: "",
            genTime: String(Int(Date().timeIntervalSince1970)),
            extra: [
                "x": Double(dragX),
                "duration_ms": durationMS,
                "track": points.map { ["x": $0.x, "y": $0.y, "t": $0.t] },
                "surface": "ios"
            ]
        )
        state.completeSlideCaptcha(ticket)
    }
}

private struct SlideCaptchaDragPoint {
    let x: Double
    let y: Double
    let t: Int
}

private extension UIImage {
    static func slideCaptchaDataURL(_ value: String) -> UIImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let payload: String
        if let comma = trimmed.firstIndex(of: ",") {
            payload = String(trimmed[trimmed.index(after: comma)...])
        } else {
            payload = trimmed
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
    }
}

private struct AuthBrandHeader: View {
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    @EnvironmentObject private var state: AppState
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    var body: some View {
        HStack(spacing: 0) {
            AuthBrandLockup(
                logoSize: 52,
                logoCornerRadius: 16,
                titleSize: 21,
                subtitleSize: 11,
                // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                onLogoTap: {
                    state.registerAccessDiagnosticsLogoTap(entry: .loggedOutLoginLogo)
                }
                // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
            )
            Spacer()
        }
    }
}

private struct AuthBrandLockup: View {
    let logoSize: CGFloat
    let logoCornerRadius: CGFloat
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    var onLogoTap: (() -> Void)? = nil
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("LoginLogo")
                .resizable()
                .scaledToFill()
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: logoCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: logoCornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                )
                .shadow(color: IMColor.brand.opacity(0.28), radius: 15, y: 8)
                // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
                .contentShape(RoundedRectangle(cornerRadius: logoCornerRadius, style: .continuous))
                .onTapGesture {
                    onLogoTap?()
                }
                // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

            VStack(alignment: .leading, spacing: 7) {
                Text("问达通")
                    .font(.system(size: titleSize, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [IMColor.ink, Color(hex: 0x2B3558)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .white.opacity(0.55), radius: 0, x: 0, y: 1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(IMColor.brand.opacity(0.72))
                        .frame(width: 4, height: 4)
                    Text("高效简洁沟通")
                        .font(.system(size: subtitleSize, weight: .bold))
                        .foregroundStyle(IMColor.muted.opacity(0.92))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.46))
                        .overlay(Capsule().stroke(.white.opacity(0.52), lineWidth: 0.8))
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// 斜线圆弧过渡:x 线性平移、y 二次曲线(走弧线)、带轻微旋转
private struct ArcOffset: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    var fromLeading: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let dir: CGFloat = fromLeading ? -1 : 1
        return content
            .offset(x: dir * progress * 620, y: -(progress * progress) * 72)
            .rotationEffect(.degrees(Double(dir * progress * 6)))
            .opacity(Double(1 - progress * 0.25))
    }
}

private extension AnyTransition {
    static func arc(fromLeading: Bool) -> AnyTransition {
        .modifier(active: ArcOffset(progress: 1, fromLeading: fromLeading),
                  identity: ArcOffset(progress: 0, fromLeading: fromLeading))
    }
}

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
private func dismissAuthKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

enum AuthFlipLayoutPolicy {
    static let accountLoginPreferredCardHeight: CGFloat = 568
    static let phoneLoginPreferredCardHeight: CGFloat = 624
    static let auxiliaryControlLeadingInset: CGFloat = 0
    static let focusedKeyboardBottomInset: CGFloat = 240

    static func loginCardHeight(
        phoneAuthEnabled: Bool,
        availableHeight: CGFloat,
        measuredContentHeight: CGFloat = 0
    ) -> CGFloat {
        let preferredHeight = phoneAuthEnabled
            ? phoneLoginPreferredCardHeight
            : accountLoginPreferredCardHeight
        let requiredHeight = max(preferredHeight, measuredContentHeight)
        return min(max(0, availableHeight), requiredHeight)
    }

    static func contentFitsWithoutScrolling(measuredContentHeight: CGFloat, cardHeight: CGFloat) -> Bool {
        measuredContentHeight > 0 && measuredContentHeight <= cardHeight
    }
}

struct RememberedLoginCredentialScope: Hashable {
    let appID: String
    let deviceID: String

    init(appID: String, deviceID: String) {
        self.appID = IMAPIContext.normalizedIOSAppID(appID)
        self.deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(context: IMAPIContext) {
        self.init(appID: context.appID, deviceID: context.deviceID)
    }

    fileprivate var storageKey: String {
        Data("\(appID)\u{0}\(deviceID)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct RememberedLoginCredentials: Equatable {
    let mode: LoginMode
    let identifier: String
    let password: String
}

struct RememberedLoginCredentialIdentity: Codable, Equatable {
    let mode: LoginMode
    let normalizedIdentifier: String

    init?(mode: LoginMode, identifier: String) {
        let normalizedIdentifier = Self.normalize(identifier, mode: mode)
        guard !normalizedIdentifier.isEmpty else { return nil }
        self.mode = mode
        self.normalizedIdentifier = normalizedIdentifier
    }

    static func normalize(_ identifier: String, mode: LoginMode) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .phone:
            return trimmed.filter(\.isNumber)
        case .account:
            return trimmed.precomposedStringWithCompatibilityMapping.lowercased()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case normalizedIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modeValue = try container.decode(String.self, forKey: .mode)
        guard ["phone", "account"].contains(modeValue),
              let mode = LoginMode(rawValue: modeValue == "phone" ? "手机号" : "账号") else {
            throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: container,
                debugDescription: "Unsupported remembered-login mode"
            )
        }
        let normalizedIdentifier = try container.decode(String.self, forKey: .normalizedIdentifier)
        guard let identity = Self(mode: mode, identifier: normalizedIdentifier),
              identity.normalizedIdentifier == normalizedIdentifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .normalizedIdentifier,
                in: container,
                debugDescription: "Remembered-login identifier is not canonical"
            )
        }
        self = identity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.storageValue, forKey: .mode)
        try container.encode(normalizedIdentifier, forKey: .normalizedIdentifier)
    }
}

struct RememberedLoginAutofillBinding: Equatable {
    let identity: RememberedLoginCredentialIdentity

    init?(credentials: RememberedLoginCredentials) {
        guard let identity = RememberedLoginCredentialIdentity(
            mode: credentials.mode,
            identifier: credentials.identifier
        ) else { return nil }
        self.identity = identity
    }

    func stillMatches(mode: LoginMode, identifier: String) -> Bool {
        RememberedLoginCredentialIdentity(mode: mode, identifier: identifier) == identity
    }
}

protocol RememberedLoginPreferencePersisting: AnyObject {
    func value(scope: RememberedLoginCredentialScope) -> Bool?
    func set(_ enabled: Bool, scope: RememberedLoginCredentialScope)
}

/// Persists only the user's non-secret checkbox choice. Login identifiers and
/// passwords remain exclusively under `RememberedLoginCredentialPersisting`.
final class UserDefaultsRememberedLoginPreferenceStore: RememberedLoginPreferencePersisting {
    private static let preferencePrefix = "jianhuitong.login.rememberCredentials.preference.v1"
    private static let legacyV2Prefix = "jianhuitong.login.rememberCredentials.v2"
    private static let legacyUnscopedEnabledKey = "jianhuitong.login.rememberCredentials.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func value(scope: RememberedLoginCredentialScope) -> Bool? {
        guard scopeIsUsable(scope) else { return nil }
        let key = preferenceKey(scope)
        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }

        // Capture the previous implementation's explicit choice before the
        // credential authority removes its legacy metadata during migration.
        for legacyKey in [legacyV2EnabledKey(scope), Self.legacyUnscopedEnabledKey] {
            guard let value = defaults.object(forKey: legacyKey) as? Bool else { continue }
            defaults.set(value, forKey: key)
            return value
        }
        return nil
    }

    func set(_ enabled: Bool, scope: RememberedLoginCredentialScope) {
        guard scopeIsUsable(scope) else { return }
        defaults.set(enabled, forKey: preferenceKey(scope))
    }

    private func scopeIsUsable(_ scope: RememberedLoginCredentialScope) -> Bool {
        !scope.appID.isEmpty && !scope.deviceID.isEmpty
    }

    private func preferenceKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.preferencePrefix).\(scope.storageKey)"
    }

    private func legacyV2EnabledKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2Prefix).\(scope.storageKey).enabled"
    }
}

protocol RememberedLoginCredentialPersisting: AnyObject {
    func load(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentials?

    @discardableResult
    func save(
        _ credentials: RememberedLoginCredentials,
        scope: RememberedLoginCredentialScope
    ) -> Bool

    func clear(scope: RememberedLoginCredentialScope)
}

protocol RememberedLoginSecretStoring: AnyObject {
    func data(service: String, account: String) -> Data?
    func set(_ data: Data, service: String, account: String) -> Bool
    func delete(service: String, account: String) -> Bool
}

final class SystemRememberedLoginSecretStore: RememberedLoginSecretStoring {
    func data(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    func set(_ data: Data, service: String, account: String) -> Bool {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class KeychainRememberedLoginCredentialStore: RememberedLoginCredentialPersisting {
    private struct ProtectedCredentialRecord: Codable {
        static let currentVersion = 4

        let version: Int
        let mode: String
        let normalizedIdentifier: String
        let password: String

        init(identity: RememberedLoginCredentialIdentity, password: String) {
            version = Self.currentVersion
            mode = identity.mode.storageValue
            normalizedIdentifier = identity.normalizedIdentifier
            self.password = password
        }
    }

    private struct ScopeDenyRecord: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let credentialAccounts: [String]

        init(credentialAccounts: [String]) {
            version = Self.currentVersion
            self.credentialAccounts = Array(Set(credentialAccounts.filter { !$0.isEmpty })).sorted()
        }
    }

    private static let keychainService = "jianhuitong.ios.login.remembered-credentials.v4"
    private static let indexService = "jianhuitong.ios.login.remembered-credentials-index.v4"
    private static let tombstoneService = "jianhuitong.ios.login.remembered-credentials-deny.v4"
    private static let tombstoneDefaultsPrefix = "jianhuitong.login.rememberCredentials.deny.v4"
    private static let legacyV3KeychainService = "jianhuitong.ios.login.remembered-credentials.v3"
    private static let legacyV2KeychainService = "jianhuitong.ios.login.remembered-password.v2"
    private static let legacyV2DefaultsPrefix = "jianhuitong.login.rememberCredentials.v2"
    private static let legacyEnabledKey = "jianhuitong.login.rememberCredentials.enabled"
    private static let legacyModeKey = "jianhuitong.login.rememberCredentials.mode"
    private static let legacyPhoneKey = "jianhuitong.login.rememberCredentials.phone"
    private static let legacyAccountKey = "jianhuitong.login.rememberCredentials.account"
    private static let legacyKeychainService = "jianhuitong.ios.login.remembered-password"
    private static let legacyKeychainAccount = "latest"

    private let defaults: UserDefaults
    private let secretStore: any RememberedLoginSecretStoring

    init(
        defaults: UserDefaults = .standard,
        secretStore: any RememberedLoginSecretStoring = SystemRememberedLoginSecretStore()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    func load(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentials? {
        guard scopeIsUsable(scope) else { return nil }
        guard !scopeIsBlocked(scope) else { return nil }
        guard purgeLegacyScopeRecords(scope: scope), purgeLegacyUnscopedRecord() else {
            _ = blockScope(scope)
            return nil
        }
        guard let indexData = secretStore.data(service: Self.indexService, account: scope.storageKey),
              let identity = try? JSONDecoder().decode(
                RememberedLoginCredentialIdentity.self,
                from: indexData
              ),
              let protectedData = secretStore.data(
                service: Self.keychainService,
                account: credentialAccount(scope: scope, identity: identity)
              ),
              let credentials = protectedCredentials(from: protectedData, expected: identity) else {
            clear(scope: scope)
            return nil
        }
        return credentials
    }

    @discardableResult
    func save(
        _ credentials: RememberedLoginCredentials,
        scope: RememberedLoginCredentialScope
    ) -> Bool {
        guard scopeIsUsable(scope),
              let identity = RememberedLoginCredentialIdentity(
                mode: credentials.mode,
                identifier: credentials.identifier
              ),
              !credentials.password.isEmpty else {
            clear(scope: scope)
            return false
        }
        let priorIndexData = secretStore.data(service: Self.indexService, account: scope.storageKey)
        let priorIdentity = priorIndexData.flatMap {
            try? JSONDecoder().decode(RememberedLoginCredentialIdentity.self, from: $0)
        }
        let account = credentialAccount(scope: scope, identity: identity)
        var accountsRequiringCleanup = blockedCredentialAccounts(scope)
        accountsRequiringCleanup.append(account)
        if let priorIdentity {
            accountsRequiringCleanup.append(credentialAccount(scope: scope, identity: priorIdentity))
        }
        guard blockScope(scope, credentialAccounts: accountsRequiringCleanup),
              priorIndexData == nil || priorIdentity != nil else { return false }
        let record = ProtectedCredentialRecord(identity: identity, password: credentials.password)
        guard let protectedData = try? JSONEncoder().encode(record),
              let indexData = try? JSONEncoder().encode(identity),
              secretStore.set(
            protectedData,
            service: Self.keychainService,
            account: account
        ), secretStore.data(service: Self.keychainService, account: account) == protectedData else {
            _ = deleteAndVerify(service: Self.keychainService, account: account)
            return false
        }
        let staleAccounts = Set(accountsRequiringCleanup).subtracting([account])
        for staleAccount in staleAccounts {
            guard deleteAndVerify(service: Self.keychainService, account: staleAccount) else {
                return false
            }
        }
        guard secretStore.set(
            indexData,
            service: Self.indexService,
            account: scope.storageKey
        ), secretStore.data(service: Self.indexService, account: scope.storageKey) == indexData else {
            _ = deleteAndVerify(service: Self.keychainService, account: account)
            return false
        }
        let staleCredentialsAreAbsent = staleAccounts.allSatisfy {
            secretStore.data(service: Self.keychainService, account: $0) == nil
        }
        guard purgeLegacyScopeRecords(scope: scope),
              purgeLegacyUnscopedRecord(),
              secretStore.data(service: Self.indexService, account: scope.storageKey) == indexData,
              secretStore.data(service: Self.keychainService, account: account) == protectedData,
              protectedCredentials(from: protectedData, expected: identity) != nil,
              staleCredentialsAreAbsent else { return false }
        return unblockScope(scope)
    }

    func clear(scope: RememberedLoginCredentialScope) {
        guard scopeIsUsable(scope) else { return }
        let indexData = secretStore.data(service: Self.indexService, account: scope.storageKey)
        let identity = indexData.flatMap {
            try? JSONDecoder().decode(RememberedLoginCredentialIdentity.self, from: $0)
        }
        var accountsRequiringCleanup = blockedCredentialAccounts(scope)
        if let identity {
            accountsRequiringCleanup.append(credentialAccount(scope: scope, identity: identity))
        }
        guard blockScope(scope, credentialAccounts: accountsRequiringCleanup) else { return }
        var fullyRemoved = indexData == nil || identity != nil
        for credentialAccount in Set(accountsRequiringCleanup) {
            fullyRemoved = deleteAndVerify(
                service: Self.keychainService,
                account: credentialAccount
            ) && fullyRemoved
        }
        if fullyRemoved {
            fullyRemoved = deleteAndVerify(
                service: Self.indexService,
                account: scope.storageKey
            ) && fullyRemoved
        }
        fullyRemoved = purgeLegacyScopeRecords(scope: scope) && fullyRemoved
        fullyRemoved = purgeLegacyUnscopedRecord() && fullyRemoved
        if fullyRemoved {
            _ = unblockScope(scope)
        }
    }

    private func previousIdentity(scope: RememberedLoginCredentialScope) -> RememberedLoginCredentialIdentity? {
        guard let data = secretStore.data(service: Self.indexService, account: scope.storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(RememberedLoginCredentialIdentity.self, from: data)
    }

    private func credentialAccount(
        scope: RememberedLoginCredentialScope,
        identity: RememberedLoginCredentialIdentity
    ) -> String {
        Data(
            "\(scope.storageKey)\u{0}\(identity.mode.storageValue)\u{0}\(identity.normalizedIdentifier)".utf8
        )
        .base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "=", with: "")
    }

    private func scopeIsUsable(_ scope: RememberedLoginCredentialScope) -> Bool {
        !scope.appID.isEmpty && !scope.deviceID.isEmpty
    }

    private func exactMode(_ value: String?) -> LoginMode? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "phone": return .phone
        case "account": return .account
        default: return nil
        }
    }

    private func protectedCredentials(
        from data: Data,
        expected identity: RememberedLoginCredentialIdentity
    ) -> RememberedLoginCredentials? {
        guard let record = try? JSONDecoder().decode(ProtectedCredentialRecord.self, from: data),
              record.version == ProtectedCredentialRecord.currentVersion,
              let mode = exactMode(record.mode),
              let decodedIdentity = RememberedLoginCredentialIdentity(
                mode: mode,
                identifier: record.normalizedIdentifier
              ),
              decodedIdentity == identity else {
            return nil
        }
        guard !record.password.isEmpty else { return nil }
        return RememberedLoginCredentials(
            mode: mode,
            identifier: identity.normalizedIdentifier,
            password: record.password
        )
    }

    private func clearLegacyV2Record(scope: RememberedLoginCredentialScope) -> Bool {
        defaults.removeObject(forKey: legacyV2EnabledKey(scope))
        defaults.removeObject(forKey: legacyV2ModeKey(scope))
        defaults.removeObject(forKey: legacyV2IdentifierKey(scope))
        return deleteAndVerify(
            service: Self.legacyV2KeychainService,
            account: scope.storageKey
        )
    }

    private func purgeLegacyScopeRecords(scope: RememberedLoginCredentialScope) -> Bool {
        let removedV3 = deleteAndVerify(
            service: Self.legacyV3KeychainService,
            account: scope.storageKey
        )
        let removedV2 = clearLegacyV2Record(scope: scope)
        return removedV3 && removedV2
    }

    private func legacyV2EnabledKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2DefaultsPrefix).\(scope.storageKey).enabled"
    }

    private func legacyV2ModeKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2DefaultsPrefix).\(scope.storageKey).mode"
    }

    private func legacyV2IdentifierKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.legacyV2DefaultsPrefix).\(scope.storageKey).identifier"
    }

    private func tombstoneDefaultsKey(_ scope: RememberedLoginCredentialScope) -> String {
        "\(Self.tombstoneDefaultsPrefix).\(scope.storageKey)"
    }

    private func scopeIsBlocked(_ scope: RememberedLoginCredentialScope) -> Bool {
        defaults.bool(forKey: tombstoneDefaultsKey(scope))
            || secretStore.data(service: Self.tombstoneService, account: scope.storageKey) != nil
    }

    private func blockedCredentialAccounts(_ scope: RememberedLoginCredentialScope) -> [String] {
        guard let data = secretStore.data(service: Self.tombstoneService, account: scope.storageKey),
              let record = try? JSONDecoder().decode(ScopeDenyRecord.self, from: data),
              record.version == ScopeDenyRecord.currentVersion else { return [] }
        return record.credentialAccounts
    }

    @discardableResult
    private func blockScope(
        _ scope: RememberedLoginCredentialScope,
        credentialAccounts: [String] = []
    ) -> Bool {
        defaults.set(true, forKey: tombstoneDefaultsKey(scope))
        let existingData = secretStore.data(service: Self.tombstoneService, account: scope.storageKey)
        let existingRecord: ScopeDenyRecord?
        if let existingData {
            existingRecord = try? JSONDecoder().decode(ScopeDenyRecord.self, from: existingData)
            guard existingRecord?.version == ScopeDenyRecord.currentVersion else { return false }
        } else {
            existingRecord = nil
        }
        let record = ScopeDenyRecord(
            credentialAccounts: (existingRecord?.credentialAccounts ?? []) + credentialAccounts
        )
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return secretStore.set(
            data,
            service: Self.tombstoneService,
            account: scope.storageKey
        ) && secretStore.data(
            service: Self.tombstoneService,
            account: scope.storageKey
        ) == data
    }

    @discardableResult
    private func unblockScope(_ scope: RememberedLoginCredentialScope) -> Bool {
        guard secretStore.delete(service: Self.tombstoneService, account: scope.storageKey),
              secretStore.data(service: Self.tombstoneService, account: scope.storageKey) == nil else {
            return false
        }
        defaults.removeObject(forKey: tombstoneDefaultsKey(scope))
        return !scopeIsBlocked(scope)
    }

    @discardableResult
    private func deleteAndVerify(service: String, account: String) -> Bool {
        secretStore.delete(service: service, account: account)
            && secretStore.data(service: service, account: account) == nil
    }

    private func purgeLegacyUnscopedRecord() -> Bool {
        defaults.removeObject(forKey: Self.legacyEnabledKey)
        defaults.removeObject(forKey: Self.legacyModeKey)
        defaults.removeObject(forKey: Self.legacyPhoneKey)
        defaults.removeObject(forKey: Self.legacyAccountKey)
        return deleteAndVerify(
            service: Self.legacyKeychainService,
            account: Self.legacyKeychainAccount
        )
    }
}

private enum AuthInputField: Hashable {
    case loginPhone
    case loginAccount
    case loginPassword
    case registerEnterprise
    case registerInvite
    case registerPhone
    case registerCode
    case registerAccount
    case registerPassword
    case registerConfirm
    case forgotAccount
    case forgotCode
    case forgotPassword
}

enum AuthInputFilter {
    case none
    case mainlandPhone
    case digits(maxLength: Int)
    case accountUsername
    case entryCode(maxLength: Int = 12)

    func apply(to value: String) -> String {
        switch self {
        case .none:
            return value
        case .digits(let maxLength):
            return String(value.filter(\.isNumber).prefix(maxLength))
        case .mainlandPhone:
            var result = ""
            for character in value.filter(\.isNumber) {
                switch result.count {
                case 0:
                    guard character == "1" else { continue }
                case 1:
                    guard "3456789".contains(character) else { continue }
                default:
                    break
                }
                result.append(character)
                if result.count == 11 { break }
            }
            return result
        case .accountUsername:
            return String(value.filter { character in
                guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
                let value = scalar.value
                return (65...90).contains(value)
                    || (97...122).contains(value)
                    || (48...57).contains(value)
            }.prefix(10))
        case .entryCode(let maxLength):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var scalars = String.UnicodeScalarView()
            for scalar in trimmed.unicodeScalars {
                if (97...122).contains(scalar.value),
                   let uppercased = UnicodeScalar(scalar.value - 32) {
                    scalars.append(uppercased)
                } else {
                    scalars.append(scalar)
                }
            }
            let normalized = String(scalars)
            // Keep invalid pasted content visible so the strict validator rejects it;
            // silently deleting spaces, Unicode dashes or confusables could create a
            // different valid authority-bearing code.
            return String(normalized.prefix(maxLength))
        }
    }
}

#if DEBUG
private func registrationEntryCodeDebugSummary(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let format = RegistrationFlowPolicy.normalizedEntryCode(rawValue) == nil
        ? (trimmed.isEmpty ? "empty" : "invalid")
        : "supported"
    return "present=\(!trimmed.isEmpty) length=\(trimmed.count) format=\(format)"
}
#endif

private func isCompleteAuthMainlandPhone(_ value: String) -> Bool {
    AuthInputFilter.mainlandPhone.apply(to: value).count == 11
}

// JHT_MOD_BEGIN REGISTER_PAGE_VISUAL_STYLE_20260914 - 修改开始：注册页输入框可切换为截图里的无标题样式
private enum AuthFormInputStyle: Equatable {
    case labeled
    case registrationPlain
}
// JHT_MOD_END REGISTER_PAGE_VISUAL_STYLE_20260914 - 修改结束

private struct AuthFormInput<Field: Hashable>: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let field: Field
    let focusedField: FocusState<Field?>.Binding
    var secure = false
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel = .next
    var keyboardActionTitle = "下一项"
    var filter: AuthInputFilter = .none
    var accessibilityIdentifier: String?
    // JHT_MOD_BEGIN REGISTER_PAGE_VISUAL_STYLE_20260914 - 修改开始：默认保持旧样式，注册页单独传入
    var style: AuthFormInputStyle = .labeled
    // JHT_MOD_END REGISTER_PAGE_VISUAL_STYLE_20260914 - 修改结束
    var onSubmit: () -> Void = {}
    @State private var isSecureTextVisible = false

    private var isFocused: Bool {
        focusedField.wrappedValue == field
    }

    // JHT_MOD_BEGIN REGISTER_PAGE_VISUAL_STYLE_20260914 - 修改开始：注册页只切换外观，输入框高度保持原默认值
    private var showsTitle: Bool {
        switch style {
        case .labeled: return true
        case .registrationPlain: return false
        }
    }

    private var fieldHeight: CGFloat {
        switch style {
        case .labeled: return 48
        case .registrationPlain: return 48
        }
    }

    private var fieldCornerRadius: CGFloat {
        switch style {
        case .labeled: return 16
        case .registrationPlain: return 18
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .labeled: return 14
        case .registrationPlain: return 18
        }
    }
    // JHT_MOD_END REGISTER_PAGE_VISUAL_STYLE_20260914 - 修改结束

    var body: some View {
        VStack(alignment: .leading, spacing: showsTitle ? 8 : 0) {
            if showsTitle {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            HStack(spacing: 8) {
                inputField
                    .focused(focusedField, equals: field)
                    .keyboardType(keyboard)
                    .textContentType(textContentType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(submitLabel)
                    .onSubmit(onSubmit)
                    .font(.system(size: 16, weight: .semibold))
                    .imReadableInputText()
                    .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))

                if secure {
                    Button {
                        let shouldRestoreFocus = isFocused
                        isSecureTextVisible.toggle()
                        if shouldRestoreFocus {
                            DispatchQueue.main.async {
                                focusedField.wrappedValue = field
                            }
                        }
                    } label: {
                        Image(systemName: isSecureTextVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSecureTextVisible ? "隐藏密码" : "显示密码")
                    .accessibilityHint(title)
                    .accessibilityValue(isSecureTextVisible ? "已显示" : "已隐藏")
                }
            }
            .frame(height: fieldHeight)
            .padding(.leading, horizontalPadding)
            .padding(.trailing, secure ? 6 : horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                    .fill(.white.opacity(style == .registrationPlain ? 0.94 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                            .stroke(style == .registrationPlain ? Color.black.opacity(0.045) : IMColor.line)
                    )
            )
        }
        .onChangeCompat(of: text) { _, newValue in
            let filtered = filter.apply(to: newValue)
            if filtered != newValue {
                text = filtered
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isFocused {
                    Spacer()
                    Button(keyboardActionTitle, action: onSubmit)
                        .font(.system(size: 14, weight: .bold))
                    Button("收起") {
                        focusedField.wrappedValue = nil
                        dismissAuthKeyboard()
                    }
                    .font(.system(size: 14, weight: .bold))
                }
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if secure && !isSecureTextVisible {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct RememberLoginCredentialsRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(isOn ? IMColor.brand : IMColor.muted.opacity(0.72))
                    .frame(width: 22, height: 22)
                Text("记住账号密码")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .authAuxiliaryControlLeadingAligned()
        .accessibilityLabel(isOn ? "已开启记住账号密码" : "开启记住账号密码")
        .accessibilityIdentifier("auth_remember_credentials_toggle")
    }
}

// 翻面时让卡片正/背面在 90° 处瞬切显隐(配合 3D 翻转,backface 效果)
private struct FlipOpacity: @preconcurrency AnimatableModifier {
    var pct: CGFloat = 0
    var animatableData: CGFloat {
        get { pct }
        set { pct = newValue }
    }
    func body(content: Content) -> some View {
        content.opacity(Double(pct.rounded()))
    }
}

private extension View {
    @ViewBuilder
    func authInteractiveKeyboardDismiss() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    func authAuxiliaryControlLeadingAligned() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, AuthFlipLayoutPolicy.auxiliaryControlLeadingInset)
    }

    // 不用实时毛玻璃(避免滚动时每帧重新模糊动态背景导致卡顿),改用半透明白 + 细描边,滚动顺滑。
    func authGlass(
        shadowRadius: CGFloat = 22,
        shadowY: CGFloat = 14,
        cornerRadius: CGFloat = 28,
        fillOpacity: Double = 0.86
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(fillOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(colors: [.white.opacity(0.18), .clear],
                                           startPoint: .top, endPoint: .bottom)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1)
                )
                .shadow(color: IMColor.brand.opacity(0.16), radius: shadowRadius, y: shadowY)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct LoginContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// 翻牌登录 / 注册:正面登录、背面注册;切换为 3D 翻转 + 卡片高度过渡。字段与流程与旧版一致(已去掉滑块验证)。
struct AuthFlipView: View {
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
    // 注册面自定义滚动条
    @State private var scrollContentH: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @FocusState private var focusedField: AuthInputField?

    init(initialRegister: Bool, initialMode: LoginMode = .phone, onPerformanceInteraction: @escaping () -> Void = {}) {
        _showRegister = State(initialValue: initialRegister)
        _loginMode = State(initialValue: initialMode)
        _regMode = State(initialValue: initialMode)
        self.onPerformanceInteraction = onPerformanceInteraction
    }

    private var registerCanSubmit: Bool {
        let identityReady = regMode == .phone
            ? isCompleteAuthMainlandPhone(rPhone)
            : isValidAuthAccountUsername(rAccount)
        return state.isRegistrationEnabledForAuthUI
            && (!state.isEnterpriseCodeFirstForAuthUI || state.hasUsablePreAuthEnterpriseContext)
            && !state.isAuthLoading
            && !state.isRegistrationSubmissionBlocked
            && identityReady
            && registerEntryCodeReady
            && PasswordRequirementHint.isValid(password: rPassword, confirmPassword: rConfirm)
    }

    private var registerEntryCodeReady: Bool {
        let filtered = AuthInputFilter.entryCode().apply(to: enterpriseCode)
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = RegistrationFlowPolicy.normalizedEntryCode(filtered)?.normalizedValue ?? ""
        if !trimmed.isEmpty && canonical.isEmpty { return false }
        return EnterpriseCodeAuthPresentationPolicy.registrationEntryCodeIsReady(
            enterpriseCodeFirst: state.isEnterpriseCodeFirstForAuthUI,
            registrationTenantCodeRequired: state.isRegistrationTenantCodeRequired,
            hasUsableContext: state.hasUsablePreAuthEnterpriseContext,
            normalizedEntryCode: canonical
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

    var body: some View {
        GeometryReader { geo in
            let maxCard = max(380, geo.size.height - 6)
            flipCard(maxCard: maxCard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChangeCompat(of: enterpriseCode) { _, value in
            state.cancelRegistrationSessionRecovery(changedEntryCode: value)
        }
        .onChangeCompat(of: [rPhone, rAccount, rPassword, rConfirm, rCode, String(describing: regMode)]) { _, _ in
            state.registrationFormDidChange()
        }
        .onChangeCompat(of: state.authScreen) { _, screen in
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
            if showRegister && !state.isRegistrationEnabledForAuthUI {
                showRegister = false
            }
            normalizePhoneAuthModes()
            loadRememberedLoginCredentialsIfNeeded()
#if DEBUG
            applyLicenseQuotaRegistrationPrefillIfNeeded()
#endif
        }
        .onChangeCompat(of: state.hasResolvedCurrentAppPolicyForAuthUI) { _, _ in
            normalizePhoneAuthModes()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: state.isPhoneAuthEnabledForAuthUI) { _, _ in
            normalizePhoneAuthModes()
            loadRememberedLoginCredentialsIfNeeded()
        }
        .onChangeCompat(of: state.isRegistrationEnabledForAuthUI) { _, enabled in
            if !enabled && showRegister {
                flip(toRegister: false)
            }
        }
        .onChangeCompat(of: state.hasUsablePreAuthEnterpriseContext) { _, usable in
            if state.isEnterpriseCodeFirstForAuthUI && !usable {
                state.authScreen = .enterpriseCode
            }
        }
    }

    @ViewBuilder
    private func flipCard(maxCard: CGFloat) -> some View {
        let h = AuthFlipLayoutPolicy.loginCardHeight(
            phoneAuthEnabled: state.isPhoneAuthEnabledForAuthUI,
            availableHeight: maxCard,
            measuredContentHeight: loginContentHeight
        )
        ZStack(alignment: .top) {
            if isFlipping {
                cardFace(loginFace, height: h, shadowRadius: 14, shadowY: 9)
                    .modifier(FlipOpacity(pct: showRegister ? 0 : 1))
                    .rotation3DEffect(.degrees(showRegister ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                cardFace(registerFace, height: h, shadowRadius: 14, shadowY: 9, cornerRadius: 32, fillOpacity: 0.92)
                    .modifier(FlipOpacity(pct: showRegister ? 1 : 0))
                    .rotation3DEffect(.degrees(showRegister ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            } else if showRegister {
                cardFace(registerFace, height: h, cornerRadius: 32, fillOpacity: 0.92)
            } else {
                cardFace(loginFace, height: h)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.6, dampingFraction: 0.84), value: showRegister)
    }

    private func cardFace<Content: View>(
        _ content: Content,
        height: CGFloat,
        shadowRadius: CGFloat = 22,
        shadowY: CGFloat = 14,
        cornerRadius: CGFloat = 28,
        fillOpacity: Double = 0.86
    ) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
            .authGlass(shadowRadius: shadowRadius, shadowY: shadowY, cornerRadius: cornerRadius, fillOpacity: fillOpacity)
    }

    private func flip(toRegister: Bool) {
        if toRegister && !state.isRegistrationEnabledForAuthUI {
            state.toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
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
        state.toast = AuthLegalConsentPolicy.promptMessage
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            loginLegalShake += 1
        }
    }

    private func promptRegisterLegalAgreement() {
        state.toast = AuthLegalConsentPolicy.promptMessage
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            registerLegalShake += 1
        }
    }

    private func submitLogin() {
        if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
            state.authScreen = .enterpriseCode
            return
        }
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: loginLegalAccepted,
            onRejected: promptLoginLegalAgreement
        ) else { return }
        if loginMode == .phone && !isCompleteAuthMainlandPhone(phone) {
            state.toast = "请输入 11 位中国大陆手机号；账号请切换到账号登录"
            focusedField = .loginPhone
            return
        }
        if loginMode == .account && !isValidAuthAccountUsername(account) {
            state.toast = "账号必须为 5-10 位数字或英文字母"
            focusedField = .loginAccount
            return
        }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.toast = "请输入密码"
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
            state.toast = state.registrationConfirmationMessage
            return
        }
        guard state.isRegistrationEnabledForAuthUI else {
            state.toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
            flip(toRegister: false)
            return
        }
        if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
            state.authScreen = .enterpriseCode
            return
        }
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: registerLegalAccepted,
            onRejected: promptRegisterLegalAgreement
        ) else { return }
        if regMode == .account && !isValidAuthAccountUsername(rAccount) {
            // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册账号格式提示按文档统一
            state.toast = "账号须为5–10位英文字母或数字。"
            // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            focusedField = .registerAccount
            return
        }
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册提交前按文档补齐密码与确认密码兜底提示
        if let failure = PasswordRequirementHint.validationFailure(password: rPassword, confirmPassword: rConfirm) {
            state.toast = failure.message
            focusedField = failure.focus
            return
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        let normalizedEntryCode = state.isEnterpriseCodeFirstForAuthUI
            ? ""
            : RegistrationFlowPolicy.normalizedEntryCode(enterpriseCode)?.normalizedValue ?? ""
        if !registerEntryCodeReady {
            state.toast = "请输入企业编码或邀请码"
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

    private var loginFace: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("欢迎回来")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(IMColor.ink)

                enterpriseContextBanner

                VStack(spacing: 14) {
                    if state.isPhoneAuthEnabledForAuthUI {
                        AuthModeSwitch(mode: $loginMode, suffix: "登录") {
                            handleLoginModeChanged()
                        }
                        .accessibilityIdentifier("auth_login_mode_switch")
                    }
                    if loginMode == .phone {
                        AuthFormInput(
                            title: "手机号",
                            placeholder: "请输入手机号",
                            text: $phone,
                            field: .loginPhone,
                            focusedField: $focusedField,
                            keyboard: .numberPad,
                            textContentType: .telephoneNumber,
                            filter: .mainlandPhone,
                            accessibilityIdentifier: "auth_login_phone_field"
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
                            textContentType: .username,
                            accessibilityIdentifier: "auth_login_account_field"
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
                        accessibilityIdentifier: "auth_login_password_field",
                        onSubmit: submitLogin
                    )
                }
                .padding(.top, 16)

                RememberLoginCredentialsRow(
                    isOn: Binding(
                        get: { state.rememberLoginCredentialsEnabledForAuthUI },
                        set: { state.setRememberLoginCredentialsEnabled($0) }
                    )
                )
                .padding(.top, 12)

                LegalDocumentLinksView(
                    prefix: "我已阅读并同意",
                    isAccepted: $loginLegalAccepted,
                    shakeTrigger: loginLegalShake,
                    consentAccessibilityIdentifier: "auth_login_legal_checkbox"
                )
                .padding(.top, 10)

                PrimaryButton(title: state.isAuthLoading ? "登录中..." : "登录",
                              systemImage: loginMode == .phone ? "iphone" : "person.text.rectangle",
                              disabled: state.isAuthLoading) {
                    submitLogin()
                }
                .accessibilityIdentifier("auth_login_submit_button")
                .padding(.top, 14)

                Button("忘记密码") { state.authScreen = .forgotPassword }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(IMColor.brand)   // 蓝色、可点击
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                if state.isRegistrationEnabledForAuthUI {
                    flipLink(text: "还没有账号?", accent: "注册", toRegister: true, accessibilityIdentifier: "auth_switch_to_register_button")
                        .padding(.top, 10)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { content in
                Color.clear.preference(key: LoginContentHeightKey.self, value: content.size.height)
            })
            .padding(.bottom, focusedField == nil ? 0 : AuthFlipLayoutPolicy.focusedKeyboardBottomInset)
        }
        .authInteractiveKeyboardDismiss()
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedField = nil
                    dismissAuthKeyboard()
                }
        )
        .frame(maxWidth: .infinity)
        .onPreferenceChange(LoginContentHeightKey.self) { loginContentHeight = $0 }
    }

    private var registerFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("注册账号")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(IMColor.ink)

            enterpriseContextBanner

            if state.isPhoneAuthEnabledForAuthUI {
                AuthModeSwitch(mode: $regMode, suffix: "注册") {
                    handleRegisterModeChanged()
                }
                .accessibilityIdentifier("auth_register_mode_switch")
                .padding(.top, 16)
            }

            GeometryReader { vp in
              ScrollViewReader { legalScrollProxy in
              ScrollView(showsIndicators: false) {
                VStack(spacing: 13) {
                    if !state.isEnterpriseCodeFirstForAuthUI {
                        AuthFormInput(
                            title: "企业编码或邀请码",
                            placeholder: enterpriseCodePlaceholder,
                            text: $enterpriseCode,
                            field: .registerEnterprise,
                            focusedField: $focusedField,
                            keyboard: .asciiCapable,
                            textContentType: .oneTimeCode,
                            filter: .entryCode(),
                            style: .registrationPlain,
                            onSubmit: {
                                focusedField = activeRegisterIdentityField
                            }
                        )
                        Text(state.registrationTenantCodeRequirementText)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(state.isRegistrationTenantCodeRequirementEmphasized ? IMColor.danger : IMColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if regMode == .phone {
                        AuthFormInput(
                            title: "手机号",
                            placeholder: "请输入手机号",
                            text: $rPhone,
                            field: .registerPhone,
                            focusedField: $focusedField,
                            keyboard: .numberPad,
                            textContentType: .telephoneNumber,
                            filter: .mainlandPhone,
                            style: .registrationPlain
                        ) {
                            focusedField = .registerCode
                        }
                        HStack(alignment: .bottom, spacing: 10) {
                            AuthFormInput(
                                title: "验证码",
                                placeholder: "6 位验证码",
                                text: $rCode,
                                field: .registerCode,
                                focusedField: $focusedField,
                                keyboard: .numberPad,
                                textContentType: .oneTimeCode,
                                filter: .digits(maxLength: 6),
                                style: .registrationPlain
                            ) {
                                focusedField = .registerPassword
                            }
                            Button(registerCaptchaButtonTitle) {
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
                            focusedField: $focusedField,
                            keyboard: .asciiCapable,
                            textContentType: .username,
                            filter: .accountUsername,
                            style: .registrationPlain
                        ) {
                            focusedField = .registerPassword
                        }
                    }
                    AuthFormInput(
                        title: "密码",
                        placeholder: "8-20 位数字和字母",
                        text: $rPassword,
                        field: .registerPassword,
                        focusedField: $focusedField,
                        secure: true,
                        keyboard: .asciiCapable,
                        textContentType: .newPassword,
                        style: .registrationPlain
                    ) {
                        focusedField = .registerConfirm
                    }
                    AuthFormInput(
                        title: "确认密码",
                        placeholder: "确认密码",
                        text: $rConfirm,
                        field: .registerConfirm,
                        focusedField: $focusedField,
                        secure: true,
                        keyboard: .asciiCapable,
                        textContentType: .newPassword,
                        submitLabel: .done,
                        keyboardActionTitle: "完成",
                        style: .registrationPlain
                    ) {
                        focusedField = nil
                    }
                    if !rPassword.isEmpty || !rConfirm.isEmpty {
                        PasswordRequirementHint(password: rPassword, confirmPassword: rConfirm)
                    }

                    VStack(spacing: 10) {
                        LegalDocumentLinksView(
                            prefix: "我已阅读并同意",
                            isAccepted: $registerLegalAccepted,
                            shakeTrigger: registerLegalShake,
                            consentAccessibilityIdentifier: "auth_register_legal_checkbox"
                        )
                        if state.registrationResolutionState == .pending {
                            Text(state.registrationConfirmationMessage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.brand)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("auth_registration_resolution_message")
                        }
                        PrimaryButton(
                            title: state.registrationSubmitButtonTitle,
                            systemImage: "checkmark",
                            disabled: !registerCanSubmit,
                            isLoading: state.isRegistrationSubmissionBlocked
                        ) {
                            submitRegister()
                        }
                        .accessibilityIdentifier("auth_register_submit_button")
                        flipLink(text: "已有账号?", accent: "去登录", toRegister: false, accessibilityIdentifier: "auth_switch_to_login_button")
                    }
                    .padding(.top, 4)
                    .id("register_legal_consent_anchor")
                }
                .padding(.top, 14)
                .padding(.bottom, focusedField == nil ? 18 : AuthFlipLayoutPolicy.focusedKeyboardBottomInset)
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
                          focusedField = nil
                          dismissAuthKeyboard()
                      }
              )
              .coordinateSpace(name: "regScroll")
              .onPreferenceChange(ScrollContentHeightKey.self) { scrollContentH = $0 }
              .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
              .overlay(alignment: .topTrailing) { scrollThumb(viewport: vp.size.height) }
              // “请先勾选协议”提示时,把底部协议勾选区滚进视口:
              // 长表单下注册按钮可见而协议区在屏外,用户会不知道提示指什么。
              .onChangeCompat(of: registerLegalShake) { _, trigger in
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

    private var registerCaptchaButtonTitle: String {
        if isSendingRegisterCaptcha { return "发送中" }
        if registerCaptchaCooldown > 0 { return "\(registerCaptchaCooldown)s" }
        return "获取"
    }

    @ViewBuilder
    private var enterpriseContextBanner: some View {
        if state.isEnterpriseCodeFirstForAuthUI && state.hasUsablePreAuthEnterpriseContext {
            HStack(spacing: 10) {
                CachedRemoteImage(
                    urlString: state.preAuthEnterpriseLogoURL,
                    cacheKey: state.preAuthEnterpriseContext?.tenantLogoCacheKey ?? "",
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
                    Text(state.preAuthEnterpriseContext?.tenantName ?? "")
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

    private func flipLink(text: String, accent: String, toRegister: Bool, accessibilityIdentifier: String? = nil) -> some View {
        Button { flip(toRegister: toRegister) } label: {
            HStack(spacing: 4) {
                Text(text).foregroundStyle(IMColor.muted)
                Text(accent).foregroundStyle(IMColor.brand)
            }
            .font(.system(size: 13.5, weight: .bold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
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

struct LegalDocumentLinksView: View {
    enum Style {
        case auth
        case settings
    }

    @EnvironmentObject private var state: AppState
    @Binding private var isAccepted: Bool
    let prefix: String
    var style: Style = .auth
    private let showsConsentToggle: Bool
    private let shakeTrigger: Int
    private let consentAccessibilityIdentifier: String?
    @State private var presentationRouter = LegalDocumentPresentationRouter()

    init(
        prefix: String,
        style: Style = .auth,
        isAccepted: Binding<Bool>? = nil,
        shakeTrigger: Int = 0,
        consentAccessibilityIdentifier: String? = nil
    ) {
        self.prefix = prefix
        self.style = style
        self._isAccepted = isAccepted ?? .constant(false)
        self.showsConsentToggle = isAccepted != nil
        self.shakeTrigger = shakeTrigger
        self.consentAccessibilityIdentifier = consentAccessibilityIdentifier
    }

    var body: some View {
        content
            .sheet(item: presentationBinding) { _ in
                LegalDocumentSheet(router: $presentationRouter)
                    .environmentObject(state)
            }
    }

    private var presentationBinding: Binding<LegalDocumentPresentation?> {
        Binding(
            get: { presentationRouter.presentation },
            set: { value in
                if value == nil {
                    presentationRouter.dismiss()
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .auth:
            authContent
        case .settings:
            settingsContent
        }
    }

    private var authContent: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsConsentToggle {
                consentCheckbox
            }
            authLegalText
        }
        .font(.system(size: 11.5, weight: .semibold))
        .authAuxiliaryControlLeadingAligned()
        .multilineTextAlignment(.leading)
        .modifier(AgreementShakeEffect(trigger: shakeTrigger))
    }

    private var consentCheckbox: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isAccepted.toggle()
            }
        } label: {
            Image(systemName: isAccepted ? "checkmark.square.fill" : "square")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(consentTint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAccepted ? "已勾选协议" : "勾选协议")
        .modifier(OptionalAccessibilityIdentifier(identifier: consentAccessibilityIdentifier))
    }

    private var authLegalText: some View {
        ViewThatFitsCompat(in: .horizontal) {
            HStack(spacing: 4) {
                authPrefixText
                legalAuthButton(.terms)
                Text("和")
                    .foregroundStyle(IMColor.muted)
                legalAuthButton(.privacy)
            }

            VStack(alignment: .leading, spacing: 6) {
                authPrefixText
                HStack(spacing: 10) {
                    legalAuthButton(.terms)
                    legalAuthButton(.privacy)
                }
            }
        }
    }

    private var consentTint: Color {
        if isAccepted {
            return IMColor.brand
        }
        return shakeTrigger > 0 ? IMColor.danger : IMColor.muted
    }

    private var authPrefixText: some View {
        Text(prefix)
            .foregroundStyle(IMColor.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var settingsContent: some View {
        VStack(spacing: 10) {
            ForEach(LegalDocumentType.allCases) { type in
                legalSettingsButton(type)
            }
        }
    }

    private func legalAuthButton(_ type: LegalDocumentType) -> some View {
        Button {
            open(type)
        } label: {
            HStack(spacing: 4) {
                if presentationRouter.presentation?.type == type {
                    ProgressView()
                        .scaleEffect(0.72)
                        .frame(width: 12, height: 12)
                }
                Text(type.title)
                    .underline()
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .foregroundStyle(IMColor.brand)
        }
        .buttonStyle(.plain)
        .disabled(presentationRouter.presentation != nil)
        .accessibilityIdentifier("auth_legal_\(type.rawValue)_button")
    }

    private func legalSettingsButton(_ type: LegalDocumentType) -> some View {
        Button {
            open(type)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: type.symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(IMColor.brand.opacity(0.10)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("查看平台后台下发的协议内容")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if presentationRouter.presentation?.type == type {
                    ProgressView()
                        .scaleEffect(0.78)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(IMColor.muted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.68))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(IMColor.brand.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(presentationRouter.presentation != nil)
    }

    private func open(_ type: LegalDocumentType) {
        _ = presentationRouter.present(type)
    }
}

private struct AgreementShakeEffect: GeometryEffect {
    private let travelDistance: CGFloat = 7
    private let shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    init(trigger: Int) {
        self.animatableData = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travelDistance * sin(animatableData * .pi * shakesPerUnit * 2),
                y: 0
            )
        )
    }
}

struct LegalDocumentPresentation: Identifiable, Equatable {
    enum LoadState: Equatable {
        case loading
        // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：展示受控拉取的协议正文，不把 URL 交给 Safari
        case ready(content: LegalDocumentContent)
        // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
        case failed(message: String)
    }

    let type: LegalDocumentType
    var loadState: LoadState

    var id: String { type.id }
    let accessibilityIdentifier = "legal_document_presentation"
}

struct LegalDocumentPresentationRouter {
    private(set) var presentation: LegalDocumentPresentation?

    @discardableResult
    mutating func present(_ type: LegalDocumentType) -> Bool {
        guard presentation == nil else { return false }
        presentation = LegalDocumentPresentation(type: type, loadState: .loading)
        return true
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：路由状态承载协议正文内容
    mutating func finish(content: LegalDocumentContent?, errorMessage: String?) {
        guard var current = presentation else { return }
        if let content {
            current.loadState = .ready(content: content)
        } else {
            let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            current.loadState = .failed(
                message: message.isEmpty ? "协议内容暂不可用，请稍后重试" : message
            )
        }
        presentation = current
    }
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

    @discardableResult
    mutating func retry() -> Bool {
        guard var current = presentation else { return false }
        guard case .failed = current.loadState else { return false }
        current.loadState = .loading
        presentation = current
        return true
    }

    mutating func dismiss() {
        presentation = nil
    }
}

private struct LegalDocumentSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var router: LegalDocumentPresentationRouter

    var body: some View {
        NavigationStackCompat {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(router.presentation?.type.title ?? "协议内容")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") {
                            router.dismiss()
                            dismiss()
                        }
                        .accessibilityIdentifier("legal_document_done_button")
                    }
                }
        }
        .accessibilityIdentifier(
            router.presentation?.accessibilityIdentifier ?? "legal_document_presentation"
        )
        .task(id: router.presentation?.type.id) {
            await resolveIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch router.presentation?.loadState {
        case .ready(let content):
            LegalDocumentWebView(content: content)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                Text(message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    guard router.retry() else { return }
                    Task { await resolveIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("legal_document_retry_button")
            }
            .padding(24)
            .accessibilityIdentifier("legal_document_error")
        case .loading, .none:
            ProgressView("正在加载协议内容...")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("legal_document_loading")
        }
    }

    @MainActor
    private func resolveIfNeeded() async {
        guard let presentation = router.presentation,
              presentation.loadState == .loading else { return }
        // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：客户端先受控拉取正文，再交给内嵌容器展示
        let content = await state.legalDocumentContent(for: presentation.type)
        guard router.presentation?.type == presentation.type else { return }
        router.finish(content: content, errorMessage: state.legalDocErrorMessage)
        // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
    }
}

// JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：内嵌展示协议正文并限制后续导航同源
private struct LegalDocumentWebView: UIViewRepresentable {
    let content: LegalDocumentContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedBaseURL = content.baseURL
        let loadKey = [
            content.sourceURL.absoluteString,
            String(content.manifest.manifestRevision),
            content.manifest.manifestHash
        ].joined(separator: "|")
        guard context.coordinator.loadedKey != loadKey else { return }
        context.coordinator.loadedKey = loadKey
        webView.loadHTMLString(content.displayHTML, baseURL: content.baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var allowedBaseURL: URL?
        var loadedKey: String?

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame != nil else {
                decisionHandler(.cancel)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
                return
            }
            guard let allowedBaseURL,
                  IMAPIClient.isAllowedLegalDocAssetURL(url, base: allowedBaseURL) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            guard let url = navigationResponse.response.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
                return
            }
            guard let allowedBaseURL,
                  IMAPIClient.isAllowedLegalDocAssetURL(url, base: allowedBaseURL) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
// JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

private struct AuthPage<Content: View>: View {
    let title: String
    let subtitle: String
    var showsBack = true
    /// 递增该值可让页面滚动到底部。用于“请先勾选协议”这类提示:
    /// 协议勾选区在长表单底部,提示出现时自动滚到底露出勾选区。
    var scrollToBottomTrigger = 0
    @ViewBuilder let content: Content
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if showsBack {
                        HStack {
                            IconButton(symbol: "chevron.left") {
                                state.authScreen = .welcome
                            }
                            Spacer()
                        }
                        .padding(.top, 12)
                    }

                    content
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
                Color.clear
                    .frame(height: 1)
                    .id("auth_page_bottom_anchor")
            }
            .authInteractiveKeyboardDismiss()
            .onChangeCompat(of: scrollToBottomTrigger) { _, trigger in
                guard trigger > 0 else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    scrollProxy.scrollTo("auth_page_bottom_anchor", anchor: .bottom)
                }
            }
        }
    }
}

private struct LoginWorkspaceSelectionView: View {
    @EnvironmentObject private var state: AppState
    @State private var makeDefaultWorkspace = false

    private var sortedEnterprises: [Enterprise] {
        state.enterprises.sorted { lhs, rhs in
            if lhs.isWorkspaceEnterable != rhs.isWorkspaceEnterable {
                return lhs.isWorkspaceEnterable && !rhs.isWorkspaceEnterable
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        AuthPage(title: "选择企业", subtitle: "请选择本次要进入的企业。", showsBack: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择企业")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(state.loginWorkspaceSelectionMessage ?? "该账号可进入多个企业，请选择本次要进入的企业。")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $makeDefaultWorkspace) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("设为默认企业")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(IMColor.ink)
                        Text("勾选后保存偏好，下次登录按企业状态自动进入。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: IMColor.brand))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.card))
                .accessibilityLabel("设为默认企业")

                if sortedEnterprises.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂无可选择企业")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("当前账号没有返回企业列表，请稍后重试或联系管理员。")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.card))
                } else {
                    VStack(spacing: 10) {
                        ForEach(sortedEnterprises) { enterprise in
                            let canEnterWorkspace = enterprise.isWorkspaceEnterable && enterprise.canSwitch
                            Button {
                                state.selectLoginWorkspace(enterprise, makeDefault: makeDefaultWorkspace)
                            } label: {
                                EnterpriseMiniCard(
                                    enterprise: enterprise,
                                    selected: enterprise.id == state.currentEnterprise.id && state.isAuthenticated,
                                    trailingText: trailingText(for: enterprise),
                                    logoCacheKey: state.enterpriseLogoCacheKey(for: enterprise)
                                )
                                .opacity(canEnterWorkspace ? 1 : 0.64)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isAuthLoading || !canEnterWorkspace)
                            .accessibilityLabel(accessibilityLabel(for: enterprise))
                        }
                    }
                }

                Button {
                    state.cancelLoginWorkspaceSelection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("返回登录")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(state.isAuthLoading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 436, maxHeight: 560, alignment: .top)
            .authGlass()
            .task(id: state.workspaceSelectionLogoPrefetchSignature(for: sortedEnterprises)) {
                await state.prefetchWorkspaceSelectionLogos(sortedEnterprises)
            }
        }
    }

    private func trailingText(for enterprise: Enterprise) -> String {
        if enterprise.isWorkspaceJoinPending {
            return "等待审批"
        }
        if enterprise.isWorkspaceJoinRejected {
            return "已拒绝"
        }
        if enterprise.isWorkspaceJoinApproved {
            return enterprise.canSwitch && enterprise.isWorkspaceEnterable ? "已通过" : "不可进入"
        }
        if !enterprise.isWorkspaceEnterable || !enterprise.canSwitch {
            return enterprise.workspaceDisabledDescription.isEmpty ? "不可进入" : "受限"
        }
        return enterprise.id == state.loginDefaultWorkspaceID ? "默认" : "进入"
    }

    private func accessibilityLabel(for enterprise: Enterprise) -> String {
        let reason = enterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if enterprise.isWorkspaceJoinPending {
            return "\(enterprise.name)，等待审批"
        }
        if enterprise.isWorkspaceJoinRejected {
            return "\(enterprise.name)，已拒绝"
        }
        if !reason.isEmpty {
            return "\(enterprise.name)，\(reason)"
        }
        return "\(enterprise.name)，可进入"
    }
}

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
        state.toast = AuthLegalConsentPolicy.promptMessage
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
            state.toast = "请输入 11 位中国大陆手机号；账号请切换到账号登录"
            focusedField = .loginPhone
            return
        }
        if mode == .account && account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.toast = "请输入账号"
            focusedField = .loginAccount
            return
        }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.toast = "请输入密码"
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

    var body: some View {
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

                    RememberLoginCredentialsRow(
                        isOn: Binding(
                            get: { state.rememberLoginCredentialsEnabledForAuthUI },
                            set: { state.setRememberLoginCredentialsEnabled($0) }
                        )
                    )

                    LegalDocumentLinksView(prefix: "我已阅读并同意", isAccepted: $legalAccepted, shakeTrigger: legalShake)

                    PrimaryButton(title: state.isAuthLoading ? "登录中..." : "登录", systemImage: mode == .phone ? "iphone" : "person.text.rectangle", disabled: state.isAuthLoading) {
                        submitLogin()
                    }
                }
                .glassCard(radius: 30)

                VStack(spacing: 14) {
                    if state.isRegistrationEnabledForAuthUI {
                        Button {
                            state.authScreen = state.isPhoneAuthEnabledForAuthUI ? .phoneRegister : .accountRegister
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
                        state.authScreen = .forgotPassword
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

private struct AuthModeSwitch: View {
    @Binding var mode: LoginMode
    let suffix: String
    let onChange: () -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LoginMode.allCases) { item in
                Button {
                    guard mode != item else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        mode = item
                        onChange()
                    }
                } label: {
                    ZStack {
                        if mode == item {
                            Capsule()
                                .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .leading, endPoint: .trailing))
                                .matchedGeometryEffect(id: "authModePill", in: namespace)
                                .shadow(color: IMColor.brand.opacity(0.18), radius: 10, y: 5)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: item == .phone ? "iphone" : "person.text.rectangle")
                            Text("\(item.rawValue)\(suffix)")
                        }
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(mode == item ? .white : IMColor.brand)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(
            Capsule()
                .fill(Color(hex: 0xEEF2FF).opacity(0.92))
                .overlay(Capsule().stroke(.white.opacity(0.84), lineWidth: 1))
        )
    }
}

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

    private var canSubmit: Bool {
        let identityReady = mode == .phone
            ? isCompleteAuthMainlandPhone(phone)
            : isValidAuthAccountUsername(account)
        return state.isRegistrationEnabledForAuthUI
            && (!state.isEnterpriseCodeFirstForAuthUI || state.hasUsablePreAuthEnterpriseContext)
            && !state.isAuthLoading
            && !state.isRegistrationSubmissionBlocked
            && verified
            && identityReady
            && entryCodeReady
            && PasswordRequirementHint.isValid(password: password, confirmPassword: confirmPassword)
    }

    private var entryCodeReady: Bool {
        let filtered = AuthInputFilter.entryCode().apply(to: enterpriseCode)
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = RegistrationFlowPolicy.normalizedEntryCode(filtered)?.normalizedValue ?? ""
        if !trimmed.isEmpty && canonical.isEmpty { return false }
        return EnterpriseCodeAuthPresentationPolicy.registrationEntryCodeIsReady(
            enterpriseCodeFirst: state.isEnterpriseCodeFirstForAuthUI,
            registrationTenantCodeRequired: state.isRegistrationTenantCodeRequired,
            hasUsableContext: state.hasUsablePreAuthEnterpriseContext,
            normalizedEntryCode: canonical
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
        state.toast = AuthLegalConsentPolicy.promptMessage
        focusedField = nil
        withAnimation(.linear(duration: 0.34)) {
            legalShake += 1
        }
    }

    private func submitRegister() {
        guard !state.isRegistrationSubmissionBlocked else {
            state.toast = state.registrationConfirmationMessage
            return
        }
        guard state.isRegistrationEnabledForAuthUI else {
            state.toast = EnterpriseCodeAuthPresentationPolicy.registrationDisabledMessage
            state.authScreen = state.isPhoneAuthEnabledForAuthUI ? .phoneLogin : .accountLogin
            return
        }
        if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
            state.authScreen = .enterpriseCode
            return
        }
        guard AuthLegalConsentPolicy.authorize(
            isAccepted: legalAccepted,
            onRejected: promptLegalAgreement
        ) else { return }
        if mode == .account && !isValidAuthAccountUsername(account) {
            // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册账号格式提示按文档统一
            state.toast = "账号须为5–10位英文字母或数字。"
            // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
            focusedField = .registerAccount
            return
        }
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册提交前按文档补齐密码与确认密码兜底提示
        if let failure = PasswordRequirementHint.validationFailure(password: password, confirmPassword: confirmPassword) {
            state.toast = failure.message
            focusedField = failure.focus
            return
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        let normalizedEntryCode = state.isEnterpriseCodeFirstForAuthUI
            ? ""
            : RegistrationFlowPolicy.normalizedEntryCode(enterpriseCode)?.normalizedValue ?? ""
        if !entryCodeReady {
            state.toast = "请输入企业编码或邀请码"
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

    var body: some View {
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
                        keyboard: .asciiCapable,
                        textContentType: .oneTimeCode,
                        submitLabel: .done,
                        keyboardActionTitle: "完成",
                        filter: .entryCode()
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
                if state.registrationResolutionState == .pending {
                    Text(state.registrationConfirmationMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.brand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("auth_registration_resolution_message")
                }
                PrimaryButton(title: state.registrationSubmitButtonTitle, systemImage: "checkmark", disabled: !canSubmit, isLoading: state.isRegistrationSubmissionBlocked) {
                    submitRegister()
                }
            }
            .glassCard(radius: 28)
        }
        .onAppear {
            if !state.isRegistrationEnabledForAuthUI {
                state.authScreen = state.isPhoneAuthEnabledForAuthUI ? .phoneLogin : .accountLogin
            } else if state.isEnterpriseCodeFirstForAuthUI && !state.hasUsablePreAuthEnterpriseContext {
                state.authScreen = .enterpriseCode
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

private struct PasswordRequirementHint: View {
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
        VStack(alignment: .leading, spacing: 8) {
            Text("密码格式要求")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(IMColor.ink)
            RequirementRow(title: "8-20 位字符", passed: hasLength)
            RequirementRow(title: "至少包含字母和数字", passed: hasLetterAndNumber)
            RequirementRow(title: "两次输入的密码一致", passed: isMatched)
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

private struct RequirementRow: View {
    let title: String
    let passed: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(passed ? IMColor.success : IMColor.muted.opacity(0.55))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(passed ? IMColor.ink : IMColor.muted)
        }
    }
}

struct ForgotPasswordView: View {
    @EnvironmentObject private var state: AppState
    @State private var account = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var isSendingCode = false
    @State private var isResetting = false
    @State private var captchaCooldown = 0
    @FocusState private var focusedField: AuthInputField?

    private var canReset: Bool {
        !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && code.trimmingCharacters(in: .whitespacesAndNewlines).count == 6
            && newPassword.count >= 8 && newPassword.count <= 20
            && newPassword.rangeOfCharacter(from: .letters) != nil
            && newPassword.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private func backToLogin() { state.authScreen = .accountLogin }

    private func submitReset() {
        guard !isResetting else { return }
        focusedField = nil
        isResetting = true
        Task {
            let succeeded = await state.resetPassword(
                account: account,
                code: code,
                newPassword: newPassword
            )
            await MainActor.run {
                isResetting = false
                guard succeeded else { return }
                state.clearRememberedLoginCredentials()
                state.authScreen = .accountLogin
            }
        }
    }

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if captchaCooldown > 0 {
                    captchaCooldown -= 1
                }
            }
    }

    private var card: some View {
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
                    focusedField: $focusedField,
                    textContentType: .username
                ) {
                    focusedField = .forgotCode
                }
                HStack(alignment: .bottom, spacing: 10) {
                    AuthFormInput(
                        title: "验证码",
                        placeholder: "6 位验证码",
                        text: $code,
                        field: .forgotCode,
                        focusedField: $focusedField,
                        keyboard: .numberPad,
                        textContentType: .oneTimeCode,
                        filter: .digits(maxLength: 6)
                    ) {
                        focusedField = .forgotPassword
                    }
                    Button(forgotCaptchaTitle) {
                        guard !isSendingCode, captchaCooldown == 0 else { return }
                        isSendingCode = true
                        Task {
                            let cooldown = await state.sendPasswordResetCaptcha(account: account)
                            await MainActor.run {
                                isSendingCode = false
                                if let cooldown {
                                    captchaCooldown = cooldown
                                }
                            }
                        }
                    }
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
                    focusedField: $focusedField,
                    secure: true,
                    keyboard: .asciiCapable,
                    textContentType: .newPassword,
                    submitLabel: .done,
                    keyboardActionTitle: "完成"
                ) {
                    focusedField = nil
                }
            }
            .padding(.top, 18)

            PrimaryButton(title: isResetting ? "正在重置" : "重置密码", systemImage: "lock.rotation", disabled: !canReset || isResetting) {
                submitReset()
            }
            .padding(.top, 28)   // 新密码↔重置 间距加大(≈2×)

            Spacer(minLength: 12)

            Button { backToLogin() } label: {
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

struct EnterpriseMiniCard: View {
    let enterprise: Enterprise
    var selected = false
    var trailingText: String?
    var logoCacheKey: String = ""

    private var canEnterWorkspace: Bool {
        enterprise.isWorkspaceEnterable && enterprise.canSwitch
    }

    private var unavailableText: String {
        guard !canEnterWorkspace else { return "" }
        let reason = enterprise.workspaceDisabledDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "暂不可进入" : reason
    }

    private var shouldShowUnavailableText: Bool {
        guard !unavailableText.isEmpty else { return false }
        return unavailableText != trailingText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 10) {
            EnterpriseLogoView(enterprise: enterprise, size: 52, cornerRadius: 18, cacheKey: logoCacheKey)
            VStack(alignment: .leading, spacing: 5) {
                Text(enterprise.name)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !enterprise.displayCode.isEmpty {
                    Text("企业码 \(enterprise.displayCode)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                if shouldShowUnavailableText {
                    Text(unavailableText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .lineLimit(1)
                }
                let inviteLine = enterprise.searchInviteDisplayLine
                if !inviteLine.isEmpty {
                    Text(inviteLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(IMColor.success)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("当前企业")
            } else if let trailingText {
                Text(trailingText)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(canEnterWorkspace ? IMColor.brand : IMColor.danger)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill((canEnterWorkspace ? IMColor.brand : IMColor.danger).opacity(0.10)))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected ? Color(hex: 0xF7FFFB) : IMColor.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(selected ? IMColor.success.opacity(0.34) : IMColor.line, lineWidth: 1)
                )
        )
    }
}

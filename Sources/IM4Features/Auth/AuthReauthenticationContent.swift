// WDT_IOS1_FEATURES_AUTH_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public enum AuthReauthenticationField: Hashable { case identifier, password, enterpriseCode }
public struct AuthReauthenticationContent: View {
    @Binding var identifier: String
    @Binding var password: String
    @Binding var enterpriseCode: String
    let focusedField: FocusState<AuthReauthenticationField?>.Binding
    let isSubmitting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void
    public init(identifier: Binding<String>, password: Binding<String>, enterpriseCode: Binding<String>,
                focusedField: FocusState<AuthReauthenticationField?>.Binding, isSubmitting: Bool, errorMessage: String?,
                onCancel: @escaping () -> Void, onSubmit: @escaping () -> Void) {
        _identifier = identifier; _password = password; _enterpriseCode = enterpriseCode; self.focusedField = focusedField
        self.isSubmitting = isSubmitting; self.errorMessage = errorMessage; self.onCancel = onCancel; self.onSubmit = onSubmit
    }
    public var body: some View {
        ZStack {
    // WDT_IOS1_REFACTOR_SESSION_REAUTHENTICATION_OBSERVATION_20261110_END
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("重新验证登录")
                            .font(.system(size: 24, weight: .bold))
                        Spacer()
                        Button("取消", action: onCancel)
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
                                .focused(focusedField, equals: .identifier)
                                .accessibilityIdentifier("session_reauthentication_identifier")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("密码")
                                .font(.subheadline.weight(.semibold))
                            SecureField("请输入当前账号密码", text: $password)
                                .textContentType(.password)
                                .focused(focusedField, equals: .password)
                                .accessibilityIdentifier("session_reauthentication_password")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("企业码（可选）")
                                .font(.subheadline.weight(.semibold))
                            TextField("应用策略要求时请填写", text: $enterpriseCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused(focusedField, equals: .enterpriseCode)
                                .accessibilityIdentifier("session_reauthentication_enterprise_code")
                        }
                    }
                    .im4ImReadableInputText()
                    .disabled(isSubmitting)
                    .im4PlainCard(radius: 22)

                    if let error = errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(IMColor.danger)
                            .accessibilityIdentifier("session_reauthentication_error")
                    }

                    Button(action: onSubmit) {
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
    }
}
// WDT_IOS1_FEATURES_AUTH_UI_20261111_END

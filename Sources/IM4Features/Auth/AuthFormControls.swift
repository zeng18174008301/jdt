import SwiftUI
import UIKit
import IM4DesignSystem

public enum AuthInputField: Hashable, Sendable {
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

public enum AuthInputFilter: Sendable {
    case none
    case mainlandPhone
    case digits(maxLength: Int)
    case accountUsername
    case entryCode(maxLength: Int = 12)

    public func apply(to value: String) -> String {
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

public enum AuthFormInputStyle: Equatable, Sendable {
    case labeled
    case registrationPlain
}

public struct AuthFormInput<Field: Hashable>: View {
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

    public init(title: String, placeholder: String, text: Binding<String>, field: Field,
                focusedField: FocusState<Field?>.Binding, secure: Bool = false,
                keyboard: UIKeyboardType = .default, textContentType: UITextContentType? = nil,
                submitLabel: SubmitLabel = .next, keyboardActionTitle: String = "下一项",
                filter: AuthInputFilter = .none, accessibilityIdentifier: String? = nil,
                style: AuthFormInputStyle = .labeled, onSubmit: @escaping () -> Void = {}) {
        self.title = title; self.placeholder = placeholder; self._text = text; self.field = field
        self.focusedField = focusedField; self.secure = secure; self.keyboard = keyboard
        self.textContentType = textContentType; self.submitLabel = submitLabel
        self.keyboardActionTitle = keyboardActionTitle; self.filter = filter
        self.accessibilityIdentifier = accessibilityIdentifier; self.style = style; self.onSubmit = onSubmit
    }

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

    public var body: some View {
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
                    .im4AuthReadableInputText()
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
        .im4AuthOnChangeCompat(of: text) { _, newValue in
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
                        dismissFeatureAuthKeyboard()
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

public struct RememberLoginCredentialsRowContent: View {
    let isOn: Bool
    let onToggle: () -> Void
    public init(isOn: Bool, onToggle: @escaping () -> Void) { self.isOn = isOn; self.onToggle = onToggle }
    public var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) { onToggle() }
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


public struct FlipOpacity: @preconcurrency AnimatableModifier {
    public var pct: CGFloat = 0
    public init(pct: CGFloat = 0) { self.pct = pct }
    public var animatableData: CGFloat {
        get { pct }
        set { pct = newValue }
    }
    public func body(content: Content) -> some View {
        content.opacity(Double(pct.rounded()))
    }
}

public extension View {
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

public struct ScrollContentHeightKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
public struct ScrollOffsetKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
public struct LoginContentHeightKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


@MainActor
private func dismissFeatureAuthKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private extension View {
    func im4AuthReadableInputText() -> some View { DesignSystemModuleExports.imReadableInputText(self) }
    func im4AuthOnChangeCompat<Value: Equatable>(of value: Value,
        perform action: @escaping (Value, Value) -> Void) -> some View {
        DesignSystemModuleExports.onChangeCompat(self, of: value, perform: action)
    }
}

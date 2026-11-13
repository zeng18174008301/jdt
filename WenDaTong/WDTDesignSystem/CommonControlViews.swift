// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_BEGIN
import Foundation
import SwiftUI
import UIKit

// WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_BEGIN
public struct CommittedSearchInput: UIViewRepresentable {
    @Binding private var text: String
    private let placeholder: String
    private let focus: Binding<Bool>?
    private let font: UIFont
    // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113
    private let placeholderColor: UIColor?
    private let onSubmit: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String,
        focus: Binding<Bool>? = nil,
        font: UIFont = .preferredFont(forTextStyle: .subheadline),
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113
        placeholderColor: UIColor? = nil,
        onSubmit: @escaping () -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.focus = focus
        self.font = font
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113
        self.placeholderColor = placeholderColor
        self.onSubmit = onSubmit
    }

    public func makeCoordinator() -> Coordinator { Coordinator(input: self) }

    public func makeUIView(context: Context) -> UITextField {
        let field = SearchTextField()
        field.delegate = context.coordinator
        field.returnKeyType = .search
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.didUnmarkText = { [weak coordinator = context.coordinator] in
            coordinator?.editingChanged($0)
        }
        return field
    }

    public func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.input = self
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_BEGIN
        if let placeholderColor {
            field.attributedPlaceholder = NSAttributedString(string: placeholder,
                attributes: [.foregroundColor: placeholderColor])
        } else {
            field.placeholder = placeholder
        }
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_END
        field.font = font
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
        context.coordinator.updateFocus(field)
    }

    @MainActor
    public final class Coordinator: NSObject, UITextFieldDelegate {
        fileprivate var input: CommittedSearchInput
        private var focusUpdateScheduled = false

        fileprivate init(input: CommittedSearchInput) { self.input = input }

        @objc fileprivate func editingChanged(_ field: UITextField) {
            guard field.markedTextRange == nil, let value = field.text, value != input.text else { return }
            input.text = value
        }

        public func textFieldDidBeginEditing(_ textField: UITextField) {
            setFocus(true)
        }

        public func textFieldDidEndEditing(_ textField: UITextField) {
            editingChanged(textField)
            setFocus(false)
        }

        public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField.markedTextRange == nil else { return true }
            editingChanged(textField)
            input.onSubmit()
            textField.resignFirstResponder()
            return false
        }

        fileprivate func updateFocus(_ field: UITextField) {
            guard let desiredFocus = input.focus?.wrappedValue, desiredFocus != field.isFirstResponder,
                  !focusUpdateScheduled else { return }
            focusUpdateScheduled = true
            Task { @MainActor [weak self, weak field] in
                guard let self else { return }
                focusUpdateScheduled = false
                guard let field, field.window != nil, let desiredFocus = input.focus?.wrappedValue,
                      desiredFocus != field.isFirstResponder else { return }
                if desiredFocus { field.becomeFirstResponder() } else { field.resignFirstResponder() }
            }
        }

        private func setFocus(_ value: Bool) {
            if let focus = input.focus, focus.wrappedValue != value {
                focus.wrappedValue = value
            }
        }
    }

    private final class SearchTextField: UITextField {
        var didUnmarkText: ((UITextField) -> Void)?

        override func unmarkText() {
            super.unmarkText()
            didUnmarkText?(self)
        }
    }
}
// WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_END

public struct SearchField: View {
    public init(text: Binding<String>, placeholder: String = "搜索", onSearch: @escaping () -> Void = {}) {
        _text = text
        self.placeholder = placeholder
        self.onSearch = onSearch
    }

    @Binding var text: String
    @State private var isFocused = false // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113
    var placeholder = "搜索"
    var onSearch: () -> Void = {}

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IMColor.muted)
            // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_BEGIN
            CommittedSearchInput(
                text: $text,
                placeholder: placeholder,
                focus: $isFocused,
                onSubmit: performSearch
            )
            // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_END
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(hex: 0xB7BED0))
                }
                .buttonStyle(.plain)
            }
            Button(action: performSearch) {
                Text("搜索")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
        )
    }

    private func performSearch() {
        onSearch()
    }
}

public struct PinnedSearchHeader<Content: View>: View {
    public init(topPadding: CGFloat = 10, bottomPadding: CGFloat = 14, @ViewBuilder content: @escaping () -> Content) {
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.content = content
    }

    var topPadding: CGFloat = 10
    var bottomPadding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    public var body: some View {
        content()
            .padding(.horizontal, 18)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PinnedSearchBackground())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(IMColor.line.opacity(0.68))
                    .frame(height: 1)
            }
            .zIndex(2)
    }
}

public struct PinnedSearchTopMask: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            PinnedSearchBackground()
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }
}

private struct PinnedSearchBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                IMColor.page.opacity(0.99),
                Color(hex: 0xEEF1FF).opacity(0.98),
                Color(hex: 0xEAF8FF).opacity(0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

public enum AvatarCropBounds {
    public static func clampedScale(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public static func clampedOffset(imageSize: CGSize, previewSize: CGFloat, scale: CGFloat, proposed: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, previewSize > 0 else { return .zero }
        let baseScale = max(previewSize / imageSize.width, previewSize / imageSize.height)
        let effectiveScale = max(scale, 0.0001)
        let displayedWidth = imageSize.width * baseScale * effectiveScale
        let displayedHeight = imageSize.height * baseScale * effectiveScale
        let maxX = max(0, (displayedWidth - previewSize) / 2)
        let maxY = max(0, (displayedHeight - previewSize) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

public struct Chip: View {
    public init(title: String, isSelected: Bool = false, count: Int? = nil, countColor: Color = IMColor.brand, countFilled: Bool = false) {
        self.title = title
        self.isSelected = isSelected
        self.count = count
        self.countColor = countColor
        self.countFilled = countFilled
    }

    let title: String
    var isSelected = false
    var count: Int?
    var countColor: Color = IMColor.brand
    var countFilled = false

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count, let badgeText = UnreadBadgeFormatter.text(count) {
                Text(badgeText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(countColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? .white.opacity(0.96) : countColor.opacity(0.10))
                    )
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isSelected ? .white : IMColor.ink)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            Capsule()
                .fill(isSelected ? IMColor.brand : .white)
                .overlay(Capsule().stroke(isSelected ? IMColor.brand : IMColor.line))
        )
    }
}

public struct StatusPill: View {
    public init(title: String, color: Color = IMColor.brand, filled: Bool = false) {
        self.title = title
        self.color = color
        self.filled = filled
    }

    let title: String
    var color: Color = IMColor.brand
    var filled = false

    public var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? color : color.opacity(0.11)))
    }
}

public struct PrimaryButton: View {
    public init(title: String, systemImage: String? = nil, disabled: Bool = false, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.disabled = disabled
        self.isLoading = isLoading
        self.action = action
    }

    let title: String
    var systemImage: String?
    var disabled = false
    var isLoading = false
    let action: () -> Void

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("处理中")
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: (disabled || isLoading) ? [Color(hex: 0xB8C0D8), Color(hex: 0xAEB6D0)] : [IMColor.brand, IMColor.violet],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        }
        .disabled(disabled || isLoading)
        .buttonStyle(.plain)
    }
}

// WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110_BEGIN
public struct CopyableUserIDText: View {
    public init(value: String, prefix: String = "", font: Font = .system(size: 12, weight: .semibold), color: Color = IMColor.muted, onCopy: @escaping @MainActor (String) -> Void) {
        self.value = value
        self.prefix = prefix
        self.font = font
        self.color = color
        self.onCopy = onCopy
    }

    let value: String
    var prefix: String = ""
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = IMColor.muted
    let onCopy: @MainActor (String) -> Void

    private var normalizedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        Text(prefix + normalizedValue)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded {
                onCopy(normalizedValue)
            })
            .accessibilityLabel(normalizedValue.isEmpty ? "用户ID为空" : "用户ID \(normalizedValue)，点击复制")
    }
}

// WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110_END

public struct IconButton: View {
    public init(symbol: String, tint: Color = IMColor.brand, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    let symbol: String
    var tint: Color = IMColor.brand
    var action: () -> Void

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

public struct FormInput: View {
    public init(title: String, placeholder: String, text: Binding<String>, secure: Bool = false, keyboard: UIKeyboardType = .default, textContentType: UITextContentType? = nil) {
        self.title = title
        self.placeholder = placeholder
        _text = text
        self.secure = secure
        self.keyboard = keyboard
        self.textContentType = textContentType
    }

    let title: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType?
    @State private var isSecureTextVisible = false
    @FocusState private var isInputFocused: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            HStack(spacing: 8) {
                inputField
                    .focused($isInputFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 16, weight: .semibold))
                    .imReadableInputText()

                if secure {
                    Button {
                        let shouldRestoreFocus = isInputFocused
                        isSecureTextVisible.toggle()
                        if shouldRestoreFocus {
                            DispatchQueue.main.async {
                                isInputFocused = true
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
            .frame(height: 48)
            .padding(.leading, 14)
            .padding(.trailing, secure ? 4 : 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
            )
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if secure && !isSecureTextVisible {
            SecureField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(resolvedTextContentType)
        } else if secure {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(resolvedTextContentType)
        } else {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(resolvedTextContentType)
        }
    }

    private var resolvedTextContentType: UITextContentType? {
        secure ? (textContentType ?? .password) : textContentType
    }
}

public enum SliderVerificationPolicy {
    public static let completionRatio: CGFloat = 0.58

    public static func clampedOffset(locationX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(locationX - 25, 0), max(width - 50, 0))
    }

    public static func completes(offset: CGFloat, width: CGFloat) -> Bool {
        offset > width * completionRatio
    }
}

public struct SliderVerification: View {
    public init(verified: Binding<Bool>) { _verified = verified }

    @Binding var verified: Bool
    @State private var dragOffset: CGFloat = 0

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(verified ? IMColor.success.opacity(0.14) : Color(hex: 0xEDF1FA))
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(verified ? IMColor.success.opacity(0.22) : IMColor.brand.opacity(0.16))
                    .frame(width: verified ? width : max(50, dragOffset + 50))
                Text(verified ? "验证通过" : "向右滑动完成验证")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(verified ? IMColor.success : IMColor.muted)
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(verified ? IMColor.success : IMColor.brand)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: verified ? "checkmark" : "chevron.right")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white)
                    )
                    .offset(x: verified ? width - 50 : dragOffset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !verified else { return }
                        dragOffset = SliderVerificationPolicy.clampedOffset(locationX: value.location.x, width: width)
                    }
                    .onEnded { _ in
                        guard !verified else { return }
                        if SliderVerificationPolicy.completes(offset: dragOffset, width: width) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                verified = true
                                dragOffset = width - 50
                            }
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityIdentifier("slider_verification")
            .accessibilityLabel(verified ? "验证通过" : "向右滑动完成验证")
            .accessibilityValue(verified ? "验证通过" : "未完成")
            .accessibilityAdjustableAction { direction in
                guard !verified else { return }
                switch direction {
                case .increment:
                    dragOffset = width - 50
                    verified = true
                case .decrement:
                    dragOffset = 0
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 50)
    }
}

public struct EmptyStateView: View {
    public init(symbol: String, title: String, subtitle: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    let symbol: String
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(width: 68, height: 68)
                .background(Circle().fill(IMColor.brand.opacity(0.12)))
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(IMColor.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(IMColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(IMColor.brand)
            }
        }
        .frame(maxWidth: .infinity)
        .plainCard(radius: 26)
    }
}

public struct RemoteLoadingStateView: View {
    public init(title: String = "正在同步真实数据", subtitle: String = "正在拉取会话、成员和消息，请稍候。") {
        self.title = title
        self.subtitle = subtitle
    }

    var title = "正在同步真实数据"
    var subtitle = "正在拉取会话、成员和消息，请稍候。"

    public var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(IMColor.brand)
                .scaleEffect(1.1)
                .frame(width: 68, height: 68)
                .background(Circle().fill(IMColor.brand.opacity(0.10)))
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(IMColor.ink)
            Text(subtitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .plainCard(radius: 26)
        .redacted(reason: .placeholder)
    }
}
// WDT_IOS1_REFACTOR_DESIGN_SYSTEM_BASE_MODULE_20261110_END

// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct UsernameEditContent: View {
    @Binding var draftUsername: String
    let hasValidLength: Bool
    let hasAllowedCharacters: Bool
    let isValid: Bool
    let isSaving: Bool
    let onClose: () -> Void
    let onSave: () -> Void

    public init(draftUsername: Binding<String>, hasValidLength: Bool, hasAllowedCharacters: Bool,
                isValid: Bool, isSaving: Bool, onClose: @escaping () -> Void, onSave: @escaping () -> Void) {
        _draftUsername = draftUsername
        self.hasValidLength = hasValidLength
        self.hasAllowedCharacters = hasAllowedCharacters
        self.isValid = isValid
        self.isSaving = isSaving
        self.onClose = onClose
        self.onSave = onSave
    }

    public var body: some View {
        ProfileEditSheetSurface {
            VStack(spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    Image(systemName: "person.text.rectangle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置用户账号")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("补充后可用于账号密码登录")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }

                    Spacer()

                    IconButton(symbol: "xmark", tint: IMColor.muted) {
                        onClose()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    FormInput(title: "用户账号", placeholder: "5-10 位数字或英文字母", text: $draftUsername, keyboard: .asciiCapable, textContentType: .username)

                    VStack(alignment: .leading, spacing: 6) {
                        usernameRule("长度 5-10 位", ok: hasValidLength)
                        usernameRule("仅支持英文字母或数字", ok: hasAllowedCharacters)
                        usernameRule("企业内唯一，保存后可用于登录", ok: true)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(IMColor.line))
                )

                PrimaryButton(title: isSaving ? "保存中..." : "保存账号", systemImage: "checkmark", disabled: !isValid || isSaving) {
                    onSave()
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func usernameRule(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(ok ? IMColor.success : IMColor.muted)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

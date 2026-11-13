// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupNicknameEditContent: View {
    @Binding var nickname: String
    let validationMessage: String?
    let inlineMessage: String?
    let clearsNickname: Bool
    let canSave: Bool
    let isSaving: Bool
    let onClose: () -> Void
    let onSave: () -> Void

    public init(nickname: Binding<String>, validationMessage: String?, inlineMessage: String?, clearsNickname: Bool,
                canSave: Bool, isSaving: Bool, onClose: @escaping () -> Void, onSave: @escaping () -> Void) {
        _nickname = nickname
        self.validationMessage = validationMessage
        self.inlineMessage = inlineMessage
        self.clearsNickname = clearsNickname
        self.canSave = canSave
        self.isSaving = isSaving
        self.onClose = onClose
        self.onSave = onSave
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            VStack(alignment: .leading, spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("我的群昵称")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("仅在当前群生效；留空保存可清除。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.78)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭群昵称编辑")
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("输入群昵称", text: $nickname)
                        .font(.system(size: 17, weight: .bold))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .im4ImReadableInputText()
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(.white.opacity(0.94))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .stroke(validationMessage == nil ? IMColor.line : IMColor.danger, lineWidth: 1)
                                )
                        )
                        .disabled(isSaving)
                        .accessibilityLabel("当前群的群昵称")
                        .accessibilityHint("最多 64 个 Unicode 字符，留空可清除")
                        .accessibilityIdentifier("group_nickname_input")

                    HStack {
                        Text(validationMessage ?? inlineMessage ?? "优先显示群昵称，未设置时显示好友备注或个人昵称。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                validationMessage != nil
                                    ? IMColor.danger
                                    : (inlineMessage?.contains("成功") == true ? IMColor.success : IMColor.muted)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text("\(nickname.unicodeScalars.count)/64")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(nickname.unicodeScalars.count > 64 ? IMColor.danger : IMColor.muted)
                            .accessibilityLabel("已输入 \(nickname.unicodeScalars.count) 个字符，最多 64 个")
                    }
                }
                .im4PlainCard(radius: 22)

                PrimaryButton(
                    title: isSaving ? "保存中..." : (clearsNickname ? "清除群昵称" : "保存群昵称"),
                    systemImage: clearsNickname ? "trash.fill" : "checkmark.circle.fill",
                    disabled: !canSave
                ) {
                    onSave()
                }
                .accessibilityIdentifier("group_nickname_save_button")
            }
            .padding(18)
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

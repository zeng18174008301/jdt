// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct NicknameEditContent<Avatar: View>: View {
    @Binding var draftName: String
    let nameCount: Int
    let isSaving: Bool
    let avatar: () -> Avatar
    let onClose: () -> Void
    let onSave: () -> Void

    public init(draftName: Binding<String>, nameCount: Int, isSaving: Bool, @ViewBuilder avatar: @escaping () -> Avatar,
                onClose: @escaping () -> Void, onSave: @escaping () -> Void) {
        _draftName = draftName
        self.nameCount = nameCount
        self.isSaving = isSaving
        self.avatar = avatar
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
                    avatar()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("修改昵称")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("昵称会显示在个人资料和你发送的消息中")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }

                    Spacer()

                    IconButton(symbol: "xmark", tint: IMColor.muted) {
                        onClose()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    FormInput(title: "昵称", placeholder: "请输入昵称", text: $draftName)

                    HStack {
                        Text("建议 2-16 个字符，支持中文、英文和数字")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        Spacer()
                        Text("\(nameCount)/16")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(nameCount > 16 ? IMColor.danger : IMColor.muted)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(IMColor.line))
                )

                PrimaryButton(title: isSaving ? "保存中..." : "保存昵称", systemImage: "checkmark", disabled: nameCount == 0 || nameCount > 16 || isSaving) {
                    onSave()
                }

                Spacer(minLength: 0)
            }
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

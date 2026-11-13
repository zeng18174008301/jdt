// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupProfileEditContent<Avatar: View>: View {
    @Binding var groupName: String
    @Binding var groupDescription: String
    let descriptionCount: Int
    let hasCroppedAvatar: Bool
    let isSaving: Bool
    let canSave: Bool
    let inlineMessage: String?
    let onClose: () -> Void
    let onPickAvatar: () -> Void
    let onSave: () -> Void
    let avatar: () -> Avatar

    public init(groupName: Binding<String>, groupDescription: Binding<String>, descriptionCount: Int,
                hasCroppedAvatar: Bool, isSaving: Bool, canSave: Bool, inlineMessage: String?,
                onClose: @escaping () -> Void, onPickAvatar: @escaping () -> Void,
                onSave: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar) {
        _groupName = groupName
        _groupDescription = groupDescription
        self.descriptionCount = descriptionCount
        self.hasCroppedAvatar = hasCroppedAvatar
        self.isSaving = isSaving
        self.canSave = canSave
        self.inlineMessage = inlineMessage
        self.onClose = onClose
        self.onPickAvatar = onPickAvatar
        self.onSave = onSave
        self.avatar = avatar
    }

    public var body: some View {
        let avatarPickerTitle = !hasCroppedAvatar ? "选择群头像" : "重新选择群头像"
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(IMColor.muted.opacity(0.22))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                    HStack(spacing: 12) {
                        avatar()
                            .shadow(color: IMColor.brand.opacity(0.12), radius: 16, y: 8)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("编辑群资料")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text("群名称和头像会同步到会话、群列表与群详情。")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.white.opacity(0.76)))
                                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭群资料编辑")
                    }

                    fields

                    Button {
                        onPickAvatar()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(avatarPickerTitle)
                                    .font(.system(size: 16, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("上传前裁剪为正方形，支持 JPG / PNG / WebP。")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.muted.opacity(0.72))
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.white.opacity(0.92))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.92), lineWidth: 1))
                                .shadow(color: IMColor.brand.opacity(0.08), radius: 18, y: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_profile_avatar_picker")

                    if let inlineMessage {
                        Text(inlineMessage)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(inlineMessage.contains("成功") ? IMColor.success : IMColor.danger)
                            .padding(.horizontal, 2)
                    }

                    PrimaryButton(title: isSaving ? "保存中..." : "保存群资料", systemImage: "checkmark.circle.fill", disabled: !canSave) {
                        onSave()
                    }
                    .accessibilityIdentifier("group_profile_save_button")
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("群名称")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(IMColor.muted)
            TextField("输入群名称", text: $groupName)
                .font(.system(size: 17, weight: .bold))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .im4ImReadableInputText()
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(.white.opacity(0.94))
                        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                )
                .accessibilityIdentifier("group_profile_name_input")
        }
        .im4PlainCard(radius: 22)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("群描述")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(IMColor.muted)
                Spacer()
                Text("\(descriptionCount) / 500")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(descriptionCount > 500 ? IMColor.danger : IMColor.muted)
                    .monospacedDigit()
            }
            TextEditor(text: $groupDescription)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IMColor.ink)
                .im4ScrollContentBackgroundHiddenCompat()
                .frame(minHeight: 110)
                .padding(10)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                .accessibilityIdentifier("group_profile_description_input")
            Text("首尾空白会自动去除；留空保存可清除群描述。")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
        }
        .im4PlainCard(radius: 22)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

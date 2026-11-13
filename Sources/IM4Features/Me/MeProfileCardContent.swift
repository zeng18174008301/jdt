// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct MeProfileCardContent<Avatar: View, Certification: View, Department: View>: View {
    let displayName: String
    let usernameIsEmpty: Bool
    let profileUserNumber: String
    let profileUsernameText: String
    let avatar: () -> Avatar
    let certification: () -> Certification
    let department: () -> Department
    let onEditAvatar: () -> Void
    let onEditNickname: () -> Void
    let onEditUsername: () -> Void
    let onCopyUserID: @MainActor (String) -> Void
    public init(displayName: String, usernameIsEmpty: Bool, userNumber: String, usernameText: String,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                @ViewBuilder department: @escaping () -> Department, onEditAvatar: @escaping () -> Void,
                onEditNickname: @escaping () -> Void, onEditUsername: @escaping () -> Void, onCopyUserID: @escaping @MainActor (String) -> Void) {
        self.displayName = displayName; self.usernameIsEmpty = usernameIsEmpty; self.profileUserNumber = userNumber
        self.profileUsernameText = usernameText; self.avatar = avatar; self.certification = certification; self.department = department
        self.onEditAvatar = onEditAvatar; self.onEditNickname = onEditNickname; self.onEditUsername = onEditUsername; self.onCopyUserID = onCopyUserID
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Button {
                    onEditAvatar()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        avatar()
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(IMColor.brand))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修改头像")

                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFitsCompat(in: .horizontal) {
                        HStack(spacing: 8) {
                            nicknameEditButton
                                .layoutPriority(4)
                            department()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            nicknameEditButton
                            department()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                profileInfoTile(
                    title: "用户ID",
                    value: profileUserNumber,
                    symbol: "number",
                    status: "点击复制",
                    statusColor: IMColor.brand,
                    copyValue: profileUserNumber
                ) {
                    onCopyUserID(profileUserNumber)
                }
                if usernameIsEmpty {
                    profileInfoTile(
                        title: "用户账号",
                        value: profileUsernameText,
                        symbol: "person.text.rectangle",
                        status: "去设置",
                        statusColor: IMColor.brand
                    ) {
                        onEditUsername()
                    }
                } else {
                    profileInfoTile(
                        title: "用户账号",
                        value: profileUsernameText,
                        symbol: "person.text.rectangle",
                        status: "已设置",
                        statusColor: IMColor.success
                    )
                }
            }
            .padding(.top, 2)
        }
        .im4GlassCard(radius: 28)
    }

    private var nicknameEditButton: some View {
        Button {
            onEditNickname()
        } label: {
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(8)
                certification()
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(IMColor.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func profileInfoTile(title: String, value: String, symbol: String, status: String, statusColor: Color, copyValue: String? = nil, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(statusColor)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(statusColor.opacity(0.12)))
                    Text(title)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                    Spacer(minLength: 0)
                }
                if let copyValue {
                    CopyableUserIDText(
                        value: copyValue,
                        font: .system(size: 13, weight: .black),
                        color: IMColor.ink,
                        onCopy: onCopyUserID // WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(value)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(status)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.62))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(statusColor.opacity(0.10), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

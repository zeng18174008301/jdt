// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ContactProfileSummaryContent<Avatar: View, Certification: View, Department: View>: View {
    let displayName: String
    let enterprise: String
    let profileUserID: String
    let remark: String
    let visiblePhone: String?
    let isCancelledProfile: Bool
    let isBlockedProfile: Bool
    let showsAvatarPreview: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    let department: () -> Department
    let onClose: () -> Void
    let onShowAvatarPreview: () -> Void
    let onCopy: @MainActor (String) -> Void

    public init(displayName: String, enterprise: String, profileUserID: String, remark: String, visiblePhone: String?,
                isCancelledProfile: Bool, isBlockedProfile: Bool, showsAvatarPreview: Bool,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                @ViewBuilder department: @escaping () -> Department, onClose: @escaping () -> Void,
                onShowAvatarPreview: @escaping () -> Void, onCopy: @escaping @MainActor (String) -> Void) {
        self.displayName = displayName
        self.enterprise = enterprise
        self.profileUserID = profileUserID
        self.remark = remark
        self.visiblePhone = visiblePhone
        self.isCancelledProfile = isCancelledProfile
        self.isBlockedProfile = isBlockedProfile
        self.showsAvatarPreview = showsAvatarPreview
        self.avatar = avatar
        self.certification = certification
        self.department = department
        self.onClose = onClose
        self.onShowAvatarPreview = onShowAvatarPreview
        self.onCopy = onCopy
    }

    private var profileCloseButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.88)))
                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭资料页")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                profileAvatar
                VStack(alignment: .leading, spacing: 7) {
                    profileIdentity
                    if isCancelledProfile {
                        StatusPill(title: "已注销", color: IMColor.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 44)

            Rectangle()
                .fill(IMColor.line.opacity(0.72))
                .frame(height: 1)

            if isBlockedProfile {
                VStack(alignment: .leading, spacing: 10) {
                    Label("该用户已在黑名单中", systemImage: "hand.raised.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.danger)
                    ProfileInfoRowContent(title: "用户ID", value: profileUserID, copyValue: profileUserID, onCopy: onCopy)
                    Text("已拉黑用户不展示完整资料，也不能发起会话、发送名片或文件。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 12) {
                    ProfileInfoRowContent(title: "企业", value: enterprise)
                    department()
                    ProfileInfoRowContent(title: "用户ID", value: profileUserID, copyValue: profileUserID, onCopy: onCopy)
                    if let visiblePhone {
                        ProfileInfoRowContent(title: "手机号", value: visiblePhone)
                    }
                    ProfileInfoRowContent(title: "备注", value: remark)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.white.opacity(0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.76), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            profileCloseButton
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
        .shadow(color: IMColor.brand.opacity(0.08), radius: 18, y: 8)
    }

    @ViewBuilder
    private var profileIdentity: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    profileName
                    profileCertification
                }
                .fixedSize(horizontal: true, vertical: true)
                stackedProfileIdentity
            }
        } else {
            // iOS 15 has no ViewThatFits; use the fully readable fallback.
            stackedProfileIdentity
        }
    }

    private var stackedProfileIdentity: some View {
        VStack(alignment: .leading, spacing: 7) {
            profileName
            profileCertification
        }
    }

    private var profileName: some View {
        Text(displayName)
            .font(.system(size: 24, weight: .black))
            .foregroundStyle(IMColor.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var profileCertification: Certification { certification() }

    @ViewBuilder
    private var profileAvatar: some View {
        if showsAvatarPreview {
            Button {
                onShowAvatarPreview()
            } label: {
                avatar()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(displayName)的头像大图")
            .accessibilityHint("打开全屏头像预览")
            .accessibilityIdentifier("other_user_avatar_preview_button")
        } else {
            avatar()
        }
    }

}

public struct ProfileInfoRowContent: View {
    let title: String
    let value: String
    var copyValue: String? = nil

    let onCopy: @MainActor (String) -> Void

    public init(title: String, value: String, copyValue: String? = nil, onCopy: @escaping @MainActor (String) -> Void = { _ in }) {
        self.title = title
        self.value = value
        self.copyValue = copyValue
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(IMColor.ink)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            guard let copyValue else { return }
            onCopy(copyValue)
        })
        .accessibilityLabel(copyValue == nil ? "\(title) \(value)" : "\(title) \(value)，点击复制")
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

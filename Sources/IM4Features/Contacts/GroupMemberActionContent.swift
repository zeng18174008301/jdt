// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupMemberActionContent<Avatar: View, Certification: View>: View {
    @State private var showRemoveConfirm = false
    @State private var showTransferConfirm = false
    let groupName: String
    let userID: String
    let userIDText: String
    let displayName: String
    let role: GroupMemberRole
    let isCurrentUserOwner: Bool
    let canManage: Bool
    let isTransferring: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onCopyUserID: @MainActor (String) -> Void
    let onClose: () -> Void
    let onViewProfile: () -> Void
    let onTransfer: () -> Void
    let onSetAdmin: (Bool) -> Void
    let onRemove: () -> Void

    public init(groupName: String, userID: String, userIDText: String, displayName: String,
                role: GroupMemberRole, isCurrentUserOwner: Bool, canManage: Bool, isTransferring: Bool,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                onCopyUserID: @escaping @MainActor (String) -> Void, onClose: @escaping () -> Void,
                onViewProfile: @escaping () -> Void, onTransfer: @escaping () -> Void,
                onSetAdmin: @escaping (Bool) -> Void, onRemove: @escaping () -> Void) {
        self.groupName = groupName
        self.userID = userID
        self.userIDText = userIDText
        self.displayName = displayName
        self.role = role
        self.isCurrentUserOwner = isCurrentUserOwner
        self.canManage = canManage
        self.isTransferring = isTransferring
        self.avatar = avatar
        self.certification = certification
        self.onCopyUserID = onCopyUserID
        self.onClose = onClose
        self.onViewProfile = onViewProfile
        self.onTransfer = onTransfer
        self.onSetAdmin = onSetAdmin
        self.onRemove = onRemove
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 14) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.24))
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    avatar()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(displayName)
                                .font(.system(size: 20, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            certification()
                            GroupRoleBadge(role: role)
                        }
                        Text(groupName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        CopyableUserIDText(
                            value: userIDText,
                            prefix: "用户ID：",
                            font: .system(size: 11, weight: .semibold),
                            color: IMColor.muted,
                            onCopy: onCopyUserID
                        )
                    }
                    Spacer()
                    IconButton(symbol: "xmark", tint: IMColor.muted) {
                        onClose()
                    }
                }

                actionContent
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .shadow(color: IMColor.brand.opacity(0.13), radius: 24, y: 10)
            )
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .alert("移出群聊？", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) {}
            Button("移出", role: .destructive) {
                onRemove()
            }
        } message: {
            Text("移出后，\(displayName) 将无法继续查看该群的新消息。")
        }
        .alert("转让群主？", isPresented: $showTransferConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认转让", role: .destructive) {
                onTransfer()
            }
        } message: {
            Text("\(displayName) 将成为群主，你将变为普通成员。此操作会立即同步给群成员。")
        }
    }

    private var actionContent: some View {
        VStack(spacing: 10) {
            GroupMemberActionRow(symbol: "person.crop.circle.fill", title: "查看资料", subtitle: "查看成员资料与可用操作", tint: IMColor.brand) {
                onViewProfile()
            }

            if role != .owner, isCurrentUserOwner {
                GroupMemberActionRow(
                    symbol: "crown.fill",
                    title: isTransferring ? "转让中..." : "转让群主",
                    subtitle: "目标成为群主，你降为普通成员",
                    tint: IMColor.warning
                ) {
                    showTransferConfirm = true
                }
                .disabled(isTransferring)
                .accessibilityIdentifier("group_owner_transfer_\(userID)")
            }

            if role == .owner {
                GroupMemberActionRow(symbol: "crown.fill", title: "群主身份不可调整", subtitle: "群主保留最高管理权限", tint: IMColor.warning) {}
                    .disabled(true)
                    .opacity(0.74)
            } else if role == .admin, isCurrentUserOwner {
                GroupMemberActionRow(symbol: "person.crop.circle.badge.minus", title: "设为普通成员", subtitle: "取消管理员权限，仍保留群成员身份", tint: IMColor.brand) {
                    onSetAdmin(false)
                }
            } else if role == .member, isCurrentUserOwner {
                GroupMemberActionRow(symbol: "checkmark.shield.fill", title: "设为管理员", subtitle: "允许管理成员、公告和成员审批", tint: IMColor.brand) {
                    onSetAdmin(true)
                }
            } else {
                GroupMemberActionRow(symbol: "checkmark.shield.fill", title: "成员权限", subtitle: "仅群主可以调整管理员身份", tint: IMColor.muted) {}
                    .disabled(true)
                    .opacity(0.74)
            }

            if role != .owner, canManage {
                GroupMemberActionRow(symbol: "person.crop.circle.badge.xmark", title: "移出群聊", subtitle: "需要二次确认后生效", tint: IMColor.danger) {
                    showRemoveConfirm = true
                }
            }
        }
    }
}

private struct GroupMemberActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(tint == IMColor.danger ? IMColor.danger : IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.7))
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(im4Hex: 0xF6F8FD)))
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

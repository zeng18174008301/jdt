// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public enum GroupMemberRole {
    case owner
    case admin
    case member

    public var title: String {
        switch self {
        case .owner: "群主"
        case .admin: "管理员"
        case .member: "成员"
        }
    }

    public var symbol: String {
        switch self {
        case .owner: "crown.fill"
        case .admin: "checkmark.shield.fill"
        case .member: "person.fill"
        }
    }

    public var color: Color {
        switch self {
        case .owner: IMColor.warning
        case .admin: IMColor.brand
        case .member: IMColor.muted
        }
    }
}

public struct GroupMemberRoleContent<Avatar: View, Certification: View>: View {
    let displayName: String
    let userIDText: String
    let role: GroupMemberRole
    let action: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onCopy: @MainActor (String) -> Void

    public init(displayName: String, userIDText: String, role: GroupMemberRole, action: @escaping () -> Void,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                onCopy: @escaping @MainActor (String) -> Void) {
        self.displayName = displayName
        self.userIDText = userIDText
        self.role = role
        self.action = action
        self.avatar = avatar
        self.certification = certification
        self.onCopy = onCopy
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        certification()
                        if role != .member {
                            GroupRoleBadge(role: role)
                        }
                    }
                    CopyableUserIDText(
                        value: userIDText,
                        prefix: "用户ID：",
                        font: .system(size: 11, weight: .semibold),
                        color: IMColor.muted,
                        onCopy: onCopy // WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110
                    )
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.75))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(role == .owner ? 0.96 : 0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(role == .owner ? IMColor.warning.opacity(0.32) : IMColor.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

public struct GroupRoleBadge: View {
    let role: GroupMemberRole

    public init(role: GroupMemberRole) { self.role = role }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: role.symbol)
                .font(.system(size: 10, weight: .black))
            Text(role.title)
                .font(.system(size: 11, weight: .black))
                .lineLimit(1)
        }
        .foregroundStyle(role.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(role.color.opacity(0.12)))
        // WDT_GROUP_ROLE_BADGE_20261021: keep the original pill from wrapping or compressing beside long names.
        .fixedSize(horizontal: true, vertical: true)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

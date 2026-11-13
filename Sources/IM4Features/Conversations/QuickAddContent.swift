// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct QuickAddMenuButton: View {
    let onOpen: () -> Void

    public init(onOpen: @escaping () -> Void) { self.onOpen = onOpen }

    public var body: some View {
        Button {
            onOpen()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(width: 44, height: 44)
                .background(Circle().fill(IMColor.brand.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation_plus_button")
        .accessibilityLabel("会话新增")
    }
}

public struct QuickAddActionSheet: View {
    let canCreateGroup: Bool
    let onClose: () -> Void
    let onDirectChat: () -> Void
    let onFindUser: () -> Void
    let onCreateGroup: () -> Void

    public init(canCreateGroup: Bool, onClose: @escaping () -> Void, onDirectChat: @escaping () -> Void,
                onFindUser: @escaping () -> Void, onCreateGroup: @escaping () -> Void) {
        self.canCreateGroup = canCreateGroup
        self.onClose = onClose
        self.onDirectChat = onDirectChat
        self.onFindUser = onFindUser
        self.onCreateGroup = onCreateGroup
    }

    public var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(IMColor.muted.opacity(0.32))
                .frame(width: 42, height: 5)
                .padding(.top, 8)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("新增")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("选择要发起的真实会话流程")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.86)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quick_add_close_button")
            }
            .padding(.horizontal, 2)

            VStack(spacing: 10) {
                QuickAddActionRow(symbol: "person.badge.plus", title: "发起单聊", subtitle: "选择当前企业好友，进入单聊会话", identifier: "quick_add_direct_chat", action: onDirectChat)
                // WDT_CHAT_FIX4_USER_ID_HINT_20261023
                QuickAddActionRow(symbol: "person.text.rectangle.fill", title: "查找用户", subtitle: "输入用户ID的纯数字部分查找同企业用户", identifier: "quick_add_find_user", action: onFindUser)
                if canCreateGroup {
                    QuickAddActionRow(symbol: "person.3.fill", title: "创建群聊", subtitle: "输入群名并调用服务端建群接口", identifier: "quick_add_create_group", action: onCreateGroup)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}

private struct QuickAddActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(IMColor.brand.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.58))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.78), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

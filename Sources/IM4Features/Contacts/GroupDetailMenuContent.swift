// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupDetailMenuContent<Nickname: View>: View {
    let canManage: Bool
    let canLeave: Bool
    let isCurrentUserOwner: Bool
    let isConversationPinned: Bool
    let pinnedMessageCount: Int
    let allMuteStatus: String
    let muteListStatus: String
    let isNotificationMuted: Bool
    let inviteConfirmRequired: Bool
    let memberFriendApplyEnabled: Bool?
    let historyVisibilityStatus: String
    let nickname: () -> Nickname
    let onAction: (GroupDetailMenuAction) -> Void

    public init(canManage: Bool, canLeave: Bool, isCurrentUserOwner: Bool, isConversationPinned: Bool, pinnedMessageCount: Int,
                allMuteStatus: String, muteListStatus: String, isNotificationMuted: Bool, inviteConfirmRequired: Bool,
                memberFriendApplyEnabled: Bool?, historyVisibilityStatus: String, @ViewBuilder nickname: @escaping () -> Nickname,
                onAction: @escaping (GroupDetailMenuAction) -> Void) {
        self.canManage = canManage
        self.canLeave = canLeave
        self.isCurrentUserOwner = isCurrentUserOwner
        self.isConversationPinned = isConversationPinned
        self.pinnedMessageCount = pinnedMessageCount
        self.allMuteStatus = allMuteStatus
        self.muteListStatus = muteListStatus
        self.isNotificationMuted = isNotificationMuted
        self.inviteConfirmRequired = inviteConfirmRequired
        self.memberFriendApplyEnabled = memberFriendApplyEnabled
        self.historyVisibilityStatus = historyVisibilityStatus
        self.nickname = nickname
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            nickname() // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
            GroupDetailMenuRow(symbol: "megaphone.fill", title: "群公告", subtitle: canManage ? "公告查看、发布" : "公告查看") {
                onAction(.announcement)
            }
            GroupDetailMenuRow(symbol: "folder.fill", title: "群文件", subtitle: "文件预览、下载、转发") {
                onAction(.files)
            }
            GroupDetailMenuRow(
                symbol: "pin.square.fill",
                title: "群内置顶消息",
                subtitle: pinnedMessageCount > 0 ? "\(pinnedMessageCount) 条置顶消息" : "查看、定位、取消置顶"
            ) {
                onAction(.pinnedMessages)
            }
            GroupDetailMenuRow(
                symbol: isConversationPinned ? "pin.slash.fill" : "pin.fill",
                title: isConversationPinned ? "取消置顶" : "置顶会话",
                subtitle: isConversationPinned ? "已固定在会话列表顶部" : "固定在会话列表顶部"
            ) {
                onAction(.togglePinned)
            }
            GroupDetailMenuDivider()
            if canManage {
                GroupDetailMenuRow(symbol: "speaker.slash.fill", title: "全员禁言", subtitle: allMuteStatus) {
                    onAction(.muteAll)
                }
            }
            GroupDetailMenuRow(
                symbol: "person.crop.circle.badge.exclamationmark.fill",
                title: "禁言名单",
                subtitle: muteListStatus,
                tint: IMColor.warning
            ) {
                onAction(.muteList)
            }
            GroupDetailMenuRow(symbol: "bell.slash.fill", title: "群免打扰", subtitle: isNotificationMuted ? "已开启" : "通知开启") {
                onAction(.mute)
            }
            GroupDetailMenuDivider()
            if canManage {
                GroupDetailMenuRow(
                    symbol: "person.badge.shield.checkmark.fill",
                    title: "入群审批",
                    subtitle: inviteConfirmRequired ? "已开启" : "未开启"
                ) {
                    onAction(.joinApproval)
                }
            }
            if canManage {
                GroupDetailMenuRow(symbol: "person.2.fill", title: "互加好友",
                    subtitle: memberFriendApplyEnabled.map { $0 ? "已开启" : "已关闭" } ?? "同步中") {
                    onAction(.memberFriendApply)
                }
            }
            GroupDetailMenuRow(
                symbol: "clock.arrow.circlepath",
                title: "新成员可查看入群前消息",
                subtitle: historyVisibilityStatus
            ) {
                onAction(.historyVisibility)
            }
            if isCurrentUserOwner {
                GroupDetailMenuDivider()
                GroupLifecycleActionRow(
                    symbol: "xmark.octagon",
                    title: "解散群聊"
                ) {
                    onAction(.dissolve)
                }
                .accessibilityIdentifier("group_detail_dissolve_button")
            } else if canLeave { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                GroupDetailMenuDivider()
                GroupLifecycleActionRow(
                    symbol: "rectangle.portrait.and.arrow.right",
                    title: "退出群聊"
                ) {
                    onAction(.leave)
                }
                .accessibilityIdentifier("group_detail_leave_button")
            }
        }
        .im4PlainCard(radius: 24)
    }
}

// WDT_GROUP_DETAIL_LAYOUT_20261021: presentation only; keep the shared settings style unchanged.
public struct GroupDetailMenuRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = IMColor.brand
    let action: () -> Void

    public init(symbol: String, title: String, subtitle: String? = nil, tint: Color = IMColor.brand, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SettingsRow(symbol: symbol, title: title, subtitle: subtitle, tint: tint, action: nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 56, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GroupDetailMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(IMColor.line)
            .frame(height: 1)
            .padding(.leading, 52)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
    }
}

struct GroupDetailInformationRow: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(IMColor.muted)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.07)))
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

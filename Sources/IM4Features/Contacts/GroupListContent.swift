// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupListContent<Managed: View, Joined: View>: View {
    let canCreateGroup: Bool
    let onCreateGroup: () -> Void
    let managed: () -> Managed
    let joined: () -> Joined

    public init(canCreateGroup: Bool, onCreateGroup: @escaping () -> Void,
                @ViewBuilder managed: @escaping () -> Managed, @ViewBuilder joined: @escaping () -> Joined) {
        self.canCreateGroup = canCreateGroup
        self.onCreateGroup = onCreateGroup
        self.managed = managed
        self.joined = joined
    }

    public var body: some View {
        List {
    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
            if canCreateGroup { // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                Section {
                    Button {
                        onCreateGroup()
                    } label: {
                        GroupCreateEntryRow()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_list_create_group_button")
                    .accessibilityLabel("创建群聊")
                }
            }

            Section("我创建 / 管理") {
                managed()
            }

            Section("我加入的") {
                joined()
            }
        }
    }
}

public struct GroupListButton<Label: View>: View {
    let groupID: String
    let groupName: String
    let onSelect: () -> Void
    let label: () -> Label

    public init(groupID: String, groupName: String, onSelect: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.groupID = groupID
        self.groupName = groupName
        self.onSelect = onSelect
        self.label = label
    }

    public var body: some View {
        Button(action: onSelect, label: label)
            .buttonStyle(.plain)
            .accessibilityIdentifier("group_list_row_\(groupID)")
            .accessibilityLabel("群聊 \(groupName)")
    }
}

public struct GroupListRowContent<Avatar: View>: View {
    let name: String
    let subtitle: String
    let isNotificationMuted: Bool
    let unread: Int?
    let avatar: () -> Avatar

    public init(name: String, subtitle: String, isNotificationMuted: Bool, unread: Int?,
                @ViewBuilder avatar: @escaping () -> Avatar) {
        self.name = name
        self.subtitle = subtitle
        self.isNotificationMuted = isNotificationMuted
        self.unread = unread
        self.avatar = avatar
    }

    private var unreadBadgeColor: Color {
        isNotificationMuted ? IMColor.muted.opacity(0.62) : IMColor.danger
    }

    public var body: some View {
        HStack(spacing: 12) {
            avatar()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                    if isNotificationMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            if let unread, let unreadText = UnreadBadgeFormatter.text(unread) {
                Text(unreadText)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(unreadBadgeColor))
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

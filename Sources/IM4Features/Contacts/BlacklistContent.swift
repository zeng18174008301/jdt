// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct BlacklistContent<Row: View>: View {
    let blacklist: [BlacklistItem]
    let row: (BlacklistItem) -> Row

    public init(blacklist: [BlacklistItem], @ViewBuilder row: @escaping (BlacklistItem) -> Row) {
        self.blacklist = blacklist
        self.row = row
    }

    public var body: some View {
        List {
            Section {
                if blacklist.isEmpty {
                    EmptyStateView(symbol: "hand.raised.slash.fill", title: "暂无黑名单账号", subtitle: "被移出的账号会恢复资料查看和会话入口。")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(blacklist) { item in
                        row(item)
                    }
                }
            } header: {
                Text("黑名单内账号无法发起会话或查看资料")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
    }
}

public struct BlacklistRowContent<Avatar: View, Certification: View>: View {
    let item: BlacklistItem
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onCopy: @MainActor (String) -> Void
    let onRemove: () -> Void

    public init(item: BlacklistItem, onRemove: @escaping () -> Void,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                onCopy: @escaping @MainActor (String) -> Void) {
        self.item = item
        self.avatar = avatar
        self.certification = certification
        self.onCopy = onCopy
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack {
            avatar()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    certification()
                }
                CopyableUserIDText(
                    value: item.id,
                    prefix: "用户ID：",
                    font: .system(size: 11, weight: .semibold),
                    color: IMColor.muted,
                    onCopy: onCopy // WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110
                )
                Text(item.reason)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            Button("移出") {
                onRemove()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("blacklist_remove_\(item.id)")
        }
        .accessibilityIdentifier("blacklist_row_\(item.id)")
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

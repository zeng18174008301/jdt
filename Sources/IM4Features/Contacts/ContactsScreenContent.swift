// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public enum ContactContentTab: String, CaseIterable, Identifiable {
    case contacts
    case organization

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .contacts: "联系人"
        case .organization: "组织架构"
        }
    }

    public var symbol: String {
        switch self {
        case .contacts: "person.2.fill"
        case .organization: "building.2.fill"
        }
    }
}


public struct ContactsScreenContent<Search: View, Alternate: View, Directory: View>: View {
    let showsAlternate: Bool
    let search: () -> Search
    let alternate: () -> Alternate
    let directory: () -> Directory
    public init(showsAlternate: Bool, @ViewBuilder search: @escaping () -> Search,
                @ViewBuilder alternate: @escaping () -> Alternate, @ViewBuilder directory: @escaping () -> Directory) {
        self.showsAlternate = showsAlternate; self.search = search; self.alternate = alternate; self.directory = directory
    }
    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                // Keep the same search field mounted when its results replace the table.
                search()
                if showsAlternate {
                    ScrollView(showsIndicators: false) {
                        alternate()
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                    }
                } else {
                    directory()
                }
            }
        }
        .overlay(alignment: .top) {
            PinnedSearchTopMask()
        }
    }
}
public struct ContactContentTabs: View {
    @Binding var activeContentTab: ContactContentTab
    public init(selection: Binding<ContactContentTab>) { _activeContentTab = selection }
    public var body: some View {
        HStack(spacing: 6) {
            ForEach(ContactContentTab.allCases) { tab in
                let selected = activeContentTab == tab
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        activeContentTab = tab
                    }
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(selected ? .white : IMColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selected ? IMColor.brand : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("contacts_tab_\(tab.rawValue)")
                .accessibilityLabel(tab.title)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.70), lineWidth: 1)
        )
    }

}
public struct ContactQuickEntriesContent: View {
    let cachedPendingFriendRequestCount: Int
    let cachedProjectedGroupCount: Int
    let cachedBlacklistCount: Int
    let pendingFriendRequestSubtitle: String
    let onSelect: (ContactRoute) -> Void
    public init(pendingRequests: Int, groupCount: Int, blacklistCount: Int, pendingSubtitle: String,
                onSelect: @escaping (ContactRoute) -> Void) {
        cachedPendingFriendRequestCount = pendingRequests; cachedProjectedGroupCount = groupCount
        cachedBlacklistCount = blacklistCount; pendingFriendRequestSubtitle = pendingSubtitle; self.onSelect = onSelect
    }
    public var body: some View {
        HStack(spacing: 10) {
            Button {
                onSelect(.newFriends)
            } label: {
                ContactEntryCard(symbol: "person.badge.plus", title: "新朋友", subtitle: pendingFriendRequestSubtitle, color: IMColor.brand, badgeCount: cachedPendingFriendRequestCount)
            }
            .accessibilityIdentifier("contacts_entry_new_friends")
            .accessibilityLabel("新朋友")
            Button {
                onSelect(.groupList)
            } label: {
                ContactEntryCard(symbol: "person.3.fill", title: "群列表", subtitle: "\(cachedProjectedGroupCount) 个群聊", color: IMColor.violet)
            }
            .accessibilityIdentifier("contacts_entry_group_list")
            .accessibilityLabel("群列表")
            Button {
                onSelect(.blacklist)
            } label: {
                ContactEntryCard(symbol: "hand.raised.fill", title: "黑名单", subtitle: "\(cachedBlacklistCount) 个账号", color: IMColor.danger)
            }
            .accessibilityIdentifier("contacts_entry_blacklist")
            .accessibilityLabel("黑名单")
        }
        .buttonStyle(.plain)
    }

}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

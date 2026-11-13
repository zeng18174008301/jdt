import IM4Features
import SwiftUI
import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

// WDT_APP_CONTRACT_20261021_09_11: bounded summary preview and the existing member/profile flows.
struct GroupDetailMemberGrid: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    let onMember: (IMUser) -> Void
    let onMembers: () -> Void

    private var members: [IMUser] {
        var seen = Set<String>()
        return group.memberPreview.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .enumerated().sorted { lhs, rhs in
                let left = rank(lhs.element)
                let right = rank(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }.prefix(19).map(\.element)
    }

    private func rank(_ user: IMUser) -> Int {
        if state.isGroupOwner(user, in: group) { return 0 }
        return state.isGroupAdmin(user, in: group) ? 1 : 2
    }

    var body: some View {
        let visibleMembers = members
        return GroupDetailMemberGridContent(isEmpty: visibleMembers.isEmpty, onMembers: onMembers, onReload: {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true, includeSecondaryData: false)
        }) {
            ForEach(visibleMembers) { user in
                GroupDetailMemberTileContent(name: GroupMemberDisplayNameResolver.projectedName(for: user), rank: rank(user),
                    onSelect: { onMember(user) }) {
                    AvatarView(name: GroupMemberDisplayNameResolver.projectedName(for: user),
                        seed: user.avatarSeed, size: 44, imageURL: user.displayAvatarURL,
                        avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt)
                }
            }
        }
    }
}

struct GroupMemberFriendApplySheet: View {
    @EnvironmentObject private var state: AppState
    let groupID: String
    @State private var isSaving = false

    private var group: GroupInfo? { state.group(id: groupID) }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
    var body: some View {
        GroupSnapshotView(store: state.contactStore, groupID: groupID) { groupContent }
    }
    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

    @ViewBuilder
    private var groupContent: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 18) {
                SheetHeader(symbol: "person.2.fill", title: "互加好友", subtitle: "允许成员从本群资料入口添加好友", showsCloseButton: true)
                Toggle("互加好友", isOn: Binding(
                    get: { group?.memberFriendApplyEnabled == true },
                    set: { value in
                        guard !isSaving else { return }
                        isSaving = true
                        Task {
                            _ = await state.setGroupMemberFriendApply(groupID: groupID, enabled: value)
                            isSaving = false
                        }
                    }
                ))
                .tint(IMColor.brand)
                .disabled(isSaving || group?.memberFriendApplyEnabled == nil || group.map { !state.canManageGroup($0) } != false)
                .plainCard(radius: 24)
                Spacer()
            }
            .padding(18)
        }
    }
}

// WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
// WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
struct GroupSnapshotView<Content: View>: View {
    let store: ContactStore
    let selectors: [ContactStore.GroupSelector]
    let content: () -> Content

    init(store: ContactStore, groupID: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(store: store, selectors: [.init(id: groupID)], content: content)
    }

    init(store: ContactStore, selectors: [ContactStore.GroupSelector], @ViewBuilder content: @escaping () -> Content) {
        self.store = store
        self.selectors = selectors
        self.content = content
    }

    var body: some View {
        PublisherSnapshotView(
            initialValue: store.groupSnapshots(matching: selectors),
            updates: store.groupUpdates(matching: selectors)
        ) { _ in
            content()
        }
    }
}
// WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END

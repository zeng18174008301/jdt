import SwiftUI

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
        // WDT_GROUP_DETAIL_LAYOUT_20261021: retain the 5-column member contract with room for names.
        VStack(alignment: .leading, spacing: 18) {
            Text("群成员")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(IMColor.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 20) {
                ForEach(members) { user in
                    Button { onMember(user) } label: {
                        VStack(spacing: 10) {
                            AvatarView(name: GroupMemberDisplayNameResolver.projectedName(for: user),
                                seed: user.avatarSeed, size: 44, imageURL: user.displayAvatarURL,
                                avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt)
                                .clipShape(Circle())
                                .overlay(alignment: .bottom) {
                                    if rank(user) < 2 {
                                        Text(rank(user) == 0 ? "群主" : "管理员")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(rank(user) == 0 ? IMColor.warning : IMColor.brand))
                                            .fixedSize()
                                            .offset(y: 4)
                                    }
                                }
                            Text(GroupMemberDisplayNameResolver.projectedName(for: user))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(IMColor.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(minHeight: 30, alignment: .top)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(GroupMemberDisplayNameResolver.projectedName(for: user))
                }
                Button(action: onMembers) {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(IMColor.brand.opacity(0.10)))
                        Text("成员列表")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(minHeight: 30, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("group_detail_member_list")
            }
            if members.isEmpty {
                Button("重新加载成员资料") {
                    state.loadGroupDetailIfNeeded(groupID: group.id, force: true, includeSecondaryData: false)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IMColor.muted)
            }
        }
        .plainCard(radius: 24)
    }
}

struct GroupMemberFriendApplySheet: View {
    @EnvironmentObject private var state: AppState
    let groupID: String
    @State private var isSaving = false

    private var group: GroupInfo? { state.group(id: groupID) }

    var body: some View {
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

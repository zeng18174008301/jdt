// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct GroupMemberManagementContent<Stats: View, Owner: View, Admins: View, Members: View>: View {
    @Binding var memberFilter: String
    let canManage: Bool
    let canInviteMembers: Bool
    let hasActiveFilter: Bool
    let hasOwner: Bool
    let hasAdmins: Bool
    let hasMembers: Bool
    let stats: () -> Stats
    let owner: () -> Owner
    let admins: () -> Admins
    let members: () -> Members
    let onInvite: () -> Void

    public init(memberFilter: Binding<String>, canManage: Bool, canInviteMembers: Bool, hasActiveFilter: Bool,
                hasOwner: Bool, hasAdmins: Bool, hasMembers: Bool, @ViewBuilder stats: @escaping () -> Stats,
                @ViewBuilder owner: @escaping () -> Owner, @ViewBuilder admins: @escaping () -> Admins,
                @ViewBuilder members: @escaping () -> Members, onInvite: @escaping () -> Void) {
        _memberFilter = memberFilter
        self.canManage = canManage
        self.canInviteMembers = canInviteMembers
        self.hasActiveFilter = hasActiveFilter
        self.hasOwner = hasOwner
        self.hasAdmins = hasAdmins
        self.hasMembers = hasMembers
        self.stats = stats
        self.owner = owner
        self.admins = admins
        self.members = members
        self.onInvite = onInvite
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "person.3.fill", title: "群成员", subtitle: canManage ? "查看群主、管理员和成员。点按成员可查看资料或管理权限。" : "查看群主、管理员和成员。点按成员可查看资料。", showsCloseButton: true)
                    stats()

                    if canInviteMembers {
                        PrimaryButton(title: "邀请好友入群", systemImage: "person.badge.plus") {
                            onInvite()
                        }
                        .accessibilityIdentifier("group_member_invite_button")
                    }

                    SearchField(text: $memberFilter, placeholder: "快速筛选姓名、账号、用户ID、手机号或拼音")

                    if hasActiveFilter, !hasOwner, !hasAdmins, !hasMembers {
                        EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有匹配的成员", subtitle: "试试姓名、用户ID、角色或拼音首字母。")
                    }

                    if hasOwner {
                        GroupMemberSection(title: "群主") {
                            owner()
                        }
                    }

                    if hasAdmins {
                        GroupMemberSection(title: "管理员") {
                            admins()
                        }
                    }

                    if !hasActiveFilter || hasMembers {
                        GroupMemberSection(title: "成员") {
                            if !hasMembers {
                                Text("暂无普通成员")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.72)))
                            } else {
                                members()
                            }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 18)
            }
        }
    }
}

private struct GroupMemberSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 4)
            LazyVStack(spacing: 10) {
                content
            }
        }
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

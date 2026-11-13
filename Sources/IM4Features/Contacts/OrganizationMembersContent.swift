// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct OrganizationMembersScreenContent<Header: View, MemberList: View>: View {
    let header: Header
    let memberList: MemberList

    public init(header: Header, memberList: MemberList) {
        self.header = header
        self.memberList = memberList
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    memberList
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
    }
}

public struct OrganizationMembersHeaderContent: View {
    let displayName: String
    let pathText: String
    let isVirtual: Bool
    let displayCount: Int

    public init(displayName: String, pathText: String, isVirtual: Bool, displayCount: Int) {
        self.displayName = displayName
        self.pathText = pathText
        self.isVirtual = isVirtual
        self.displayCount = displayCount
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isVirtual ? "building.2.fill" : "folder.fill")
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(isVirtual ? IMColor.brand : IMColor.violet)
                .frame(width: 46, height: 46)
                .background(Circle().fill((isVirtual ? IMColor.brand : IMColor.violet).opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Text(pathText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(displayCount) 人")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.brand)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(IMColor.brand.opacity(0.10)))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.9))
                .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }
}

public struct OrganizationMembersListContent<Row: View>: View {
    let isEmpty: Bool
    let isSyncing: Bool
    let rows: () -> Row

    public init(isEmpty: Bool, isSyncing: Bool, @ViewBuilder rows: @escaping () -> Row) {
        self.isEmpty = isEmpty
        self.isSyncing = isSyncing
        self.rows = rows
    }

    public var body: some View {
        if isSyncing {
            RemoteLoadingStateView(
                title: "正在同步成员",
                subtitle: "正在拉取部门成员数据。"
            )
        } else if isEmpty {
            EmptyStateView(symbol: "person.2.slash", title: "暂无成员", subtitle: "该部门当前没有成员。")
                .padding(.vertical, 8)
        } else {
            LazyVStack(spacing: 0) {
                rows()
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            )
        }
    }
}

public struct OrganizationMemberButtonContent<Label: View>: View {
    let userID: String
    let accessibilityLabel: String
    let onSelect: () -> Void
    let label: () -> Label

    public init(userID: String, accessibilityLabel: String, onSelect: @escaping () -> Void,
                @ViewBuilder label: @escaping () -> Label) {
        self.userID = userID
        self.accessibilityLabel = accessibilityLabel
        self.onSelect = onSelect
        self.label = label
    }

    public var body: some View {
        Button(action: onSelect, label: label)
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("organization_member_\(userID)")
            .accessibilityLabel(accessibilityLabel)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

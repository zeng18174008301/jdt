// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct OrganizationDepartmentContent<Children: View>: View {
    let departmentID: String
    let displayName: String
    let hasChildren: Bool
    let isVirtual: Bool
    let level: Int
    let memberCount: Int
    let onShowMembers: () -> Void
    let children: () -> Children
    @State private var isExpanded: Bool

    public init(departmentID: String, displayName: String, hasChildren: Bool, isVirtual: Bool,
                level: Int, memberCount: Int, initiallyExpanded: Bool,
                onShowMembers: @escaping () -> Void, @ViewBuilder children: @escaping () -> Children) {
        self.departmentID = departmentID
        self.displayName = displayName
        self.hasChildren = hasChildren
        self.isVirtual = isVirtual
        self.level = level
        self.memberCount = memberCount
        self.onShowMembers = onShowMembers
        self.children = children
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if hasChildren {
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        departmentLabel(memberCount: memberCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("organization_department_\(departmentID)")
                    .accessibilityLabel("部门 \(displayName)")
                } else {
                    departmentLabel(memberCount: memberCount)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("organization_department_\(departmentID)")
                        .accessibilityLabel("部门 \(displayName)")
                }

                Button {
                    onShowMembers()
                } label: {
                    Text("查看成员")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(IMColor.page.opacity(0.92)))
                        .overlay(Capsule().stroke(IMColor.brand.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("organization_view_members_\(departmentID)")
                .accessibilityLabel("查看 \(displayName) 成员")
            }
            .padding(.leading, CGFloat(level) * 18 + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 11)

            if isExpanded {
                children()
            }
        }
    }

    private func departmentLabel(memberCount: Int) -> some View { // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
        HStack(spacing: 10) {
            Image(systemName: hasChildren ? (isExpanded ? "chevron.down" : "chevron.right") : "circle.fill")
                .font(.system(size: hasChildren ? 11 : 6, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 18)
            Image(systemName: isVirtual ? "building.2.fill" : "folder.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(isVirtual ? IMColor.brand : IMColor.violet)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Text(memberCount > 0 ? "\(memberCount) 人" : "暂无成员")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

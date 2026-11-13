// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct DepartmentMemberInviteContent<Rows: View>: View {
    @Binding var query: String
    let targetDepartmentName: String
    let isEmpty: Bool
    let confirmButtonTitle: String
    let confirmDisabled: Bool
    let onSubmit: () -> Void
    let rows: () -> Rows

    public init(query: Binding<String>, targetDepartmentName: String, isEmpty: Bool,
                confirmButtonTitle: String, confirmDisabled: Bool, onSubmit: @escaping () -> Void,
                @ViewBuilder rows: @escaping () -> Rows) {
        _query = query
        self.targetDepartmentName = targetDepartmentName
        self.isEmpty = isEmpty
        self.confirmButtonTitle = confirmButtonTitle
        self.confirmDisabled = confirmDisabled
        self.onSubmit = onSubmit
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                symbol: "person.crop.circle.badge.plus",
                title: "邀请成员",
                subtitle: "搜索企业用户，确认后将主部门变更为\(targetDepartmentName)。",
                showsCloseButton: true
            )
            SearchField(text: $query, placeholder: "搜索成员、用户ID或拼音")
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if isEmpty {
                        EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有匹配成员", subtitle: "换个姓名、用户ID或拼音再试。")
                            .padding(.vertical, 12)
                    } else {
                        rows()
                    }
                }
                .padding(.vertical, 2)
            }
            PrimaryButton(title: confirmButtonTitle, systemImage: "checkmark.circle.fill", disabled: confirmDisabled) {
                onSubmit()
            }
        }
        .padding(18)
        .background(IMColor.page.ignoresSafeArea())
    }
}

public struct DepartmentMemberInviteRowContent<Avatar: View, Certification: View>: View {
    let userID: String
    let displayName: String
    let displayID: String
    let departmentName: String
    let selected: Bool
    let alreadyInTarget: Bool
    let onCopyUserID: @MainActor (String) -> Void
    let onSelect: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification

    public init(userID: String, displayName: String, displayID: String, departmentName: String,
                selected: Bool, alreadyInTarget: Bool, onCopyUserID: @escaping @MainActor (String) -> Void,
                onSelect: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.userID = userID
        self.displayName = displayName
        self.displayID = displayID
        self.departmentName = departmentName
        self.selected = selected
        self.alreadyInTarget = alreadyInTarget
        self.onCopyUserID = onCopyUserID
        self.onSelect = onSelect
        self.avatar = avatar
        self.certification = certification
    }

    public var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        certification()
                    }
                    CopyableUserIDText(
                        value: displayID,
                        prefix: "用户ID：",
                        font: .system(size: 11, weight: .semibold),
                        color: IMColor.muted,
                        onCopy: onCopyUserID
                    )
                    Label(departmentName, systemImage: "building.2.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer()
                if alreadyInTarget {
                    Text("已在当前部门")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.success)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Capsule().fill(IMColor.success.opacity(0.10)))
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(selected ? IMColor.brand : IMColor.muted.opacity(0.55))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? IMColor.brand.opacity(0.08) : .white.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? IMColor.brand.opacity(0.30) : .white.opacity(0.72), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("department_invite_candidate_\(userID)")
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

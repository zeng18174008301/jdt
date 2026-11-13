// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct GroupMuteMemberPickerContent<Rows: View>: View {
    @Binding var query: String
    @Binding var reason: String
    let isEmpty: Bool
    let hasSelection: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void
    let rows: () -> Rows

    public init(query: Binding<String>, reason: Binding<String>, isEmpty: Bool, hasSelection: Bool,
                canSubmit: Bool, onSubmit: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        _query = query
        _reason = reason
        self.isEmpty = isEmpty
        self.hasSelection = hasSelection
        self.canSubmit = canSubmit
        self.onSubmit = onSubmit
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(
                        symbol: "person.badge.minus",
                        title: "添加禁言成员",
                        subtitle: "仅可选择群内普通成员，群主和管理员不会出现在候选列表。",
                        showsCloseButton: true
                    )
                    SearchField(text: $query, placeholder: "搜索成员、用户ID或拼音")
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if isEmpty {
                                EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有可添加成员", subtitle: "已禁言成员、群主、管理员和注销成员不会出现在这里。")
                            } else {
                                rows()
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("禁言原因")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        TextField("可选，便于后续追溯", text: $reason)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.system(size: 14, weight: .bold))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                    }
                    PrimaryButton(
                        title: !hasSelection ? "选择成员" : "加入禁言名单",
                        systemImage: "checkmark.circle.fill",
                        disabled: !canSubmit
                    ) {
                        onSubmit()
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

public struct GroupMemberSelectionRowContent<Avatar: View, Certification: View>: View {
    let displayName: String
    let displayID: String
    let isSelected: Bool
    let avatar: () -> Avatar
    let certification: () -> Certification
    let onCopyUserID: @MainActor (String) -> Void
    let onSelect: () -> Void

    public init(displayName: String, displayID: String, isSelected: Bool,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification,
                onCopyUserID: @escaping @MainActor (String) -> Void, onSelect: @escaping () -> Void) {
        self.displayName = displayName
        self.displayID = displayID
        self.isSelected = isSelected
        self.avatar = avatar
        self.certification = certification
        self.onCopyUserID = onCopyUserID
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 4) {
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
                        font: .system(size: 12, weight: .semibold),
                        color: IMColor.muted,
                        onCopy: onCopyUserID
                    )
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isSelected ? IMColor.brand : IMColor.muted.opacity(0.55))
            }
            .im4PlainCard(radius: 20)
        }
        .buttonStyle(.plain)
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

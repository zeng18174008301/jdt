// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct CreateGroupContent<Row: View>: View {
    @Binding var query: String
    let isEmpty: Bool
    let onClose: () -> Void
    let rows: () -> Row
    @Binding var groupName: String
    let selectedCount: Int
    let isSubmitting: Bool
    let onSubmit: () -> Void

    public init(query: Binding<String>, isEmpty: Bool, groupName: Binding<String>, selectedCount: Int, isSubmitting: Bool, onSubmit: @escaping () -> Void,
                onClose: @escaping () -> Void,
                @ViewBuilder rows: @escaping () -> Row) {
        _query = query
        self.isEmpty = isEmpty
        self.onClose = onClose
        self.rows = rows
        _groupName = groupName
        self.selectedCount = selectedCount
        self.isSubmitting = isSubmitting
        self.onSubmit = onSubmit
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 14) {
                    ConversationQuickSheetHeader(symbol: "person.3.sequence.fill", title: "创建群聊", subtitle: "群名必填，可直接拉入好友。普通用户无建群入口。", onClose: onClose)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("群名称")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                        TextField("输入群名称", text: $groupName)
                            .font(.system(size: 16, weight: .bold))
                            .keyboardType(.default)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(true)
                            .im4ImReadableInputText()
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.92)))
                            .accessibilityIdentifier("create_group_name_input")
                    }
                    .im4PlainCard(radius: 22)

                    SearchField(text: $query, placeholder: "搜索好友、用户ID或拼音")
                        .accessibilityIdentifier("create_group_member_search")

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            if isEmpty {
                                EmptyStateView(symbol: "person.2.slash.fill", title: "暂无可拉入好友", subtitle: "当前企业没有匹配的好友。")
                            } else {
                                rows()
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    PrimaryButton(
                        title: isSubmitting ? "创建中..." : (selectedCount == 0 ? "创建群聊" : "创建并拉入 \(selectedCount) 人"),
                        systemImage: isSubmitting ? "hourglass" : "checkmark",
                        disabled: isSubmitting || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        onSubmit()
                    }
                    .accessibilityIdentifier("create_group_submit_button")
                }
                .padding(18)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { onClose() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColor.brand)
                }
            }
        }
    }
}

public struct CreateGroupMemberContent<Avatar: View, Certification: View>: View {
    let userID: String
    let displayName: String
    let onSelect: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification
    let isSelected: Bool
    let visibleUserID: String
    let onCopy: @MainActor (String) -> Void

    public init(userID: String, displayName: String, isSelected: Bool, visibleUserID: String, onCopy: @escaping @MainActor (String) -> Void,
                onSelect: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.userID = userID
        self.displayName = displayName
        self.onSelect = onSelect
        self.avatar = avatar
        self.certification = certification
        self.isSelected = isSelected
        self.visibleUserID = visibleUserID
        self.onCopy = onCopy
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
                        value: visibleUserID,
                        prefix: "用户ID：",
                        font: .system(size: 12, weight: .semibold),
                        color: IMColor.muted,
                        onCopy: onCopy // WDT_IOS1_REFACTOR_DESIGN_ACTIONS_20261110
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
        .accessibilityIdentifier("create_group_member_row_\(userID)")
    }
}

struct ConversationQuickSheetHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.brand))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.muted)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.86)))
                    .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .im4PlainCard(radius: 24)
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct StartDirectChatContent<Row: View>: View {
    @Binding var query: String
    let isEmpty: Bool
    let onClose: () -> Void
    let rows: () -> Row

    public init(query: Binding<String>, isEmpty: Bool, onClose: @escaping () -> Void,
                @ViewBuilder rows: @escaping () -> Row) {
        _query = query
        self.isEmpty = isEmpty
        self.onClose = onClose
        self.rows = rows
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 14) {
                    ConversationQuickSheetHeader(
                        symbol: "person.badge.plus",
                        title: "发起单聊",
                        subtitle: "联系人来自当前企业好友接口，选择联系人后进入聊天。",
                        onClose: onClose
                    )

                    SearchField(text: $query, placeholder: "搜索姓名、用户ID或拼音")
                        .accessibilityIdentifier("start_direct_chat_search_field")

                    if isEmpty {
                        EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有联系人", subtitle: "当前企业没有匹配的好友数据。")
                            .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                rows()
                            }
                            .padding(.bottom, 12)
                        }
                    }
                }
                .padding(18)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        onClose()
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.brand)
                }
            }
        }
    }
}

public struct DirectChatContactContent<Avatar: View, Certification: View>: View {
    let userID: String
    let displayName: String
    let onSelect: () -> Void
    let avatar: () -> Avatar
    let certification: () -> Certification
    let hasConversation: Bool

    public init(userID: String, displayName: String, hasConversation: Bool,
                onSelect: @escaping () -> Void, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification) {
        self.userID = userID
        self.displayName = displayName
        self.onSelect = onSelect
        self.avatar = avatar
        self.certification = certification
        self.hasConversation = hasConversation
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                avatar()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        certification()
                    }
                    Text(!hasConversation ? "点击发起单聊" : "进入已有单聊")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(!hasConversation ? IMColor.muted : IMColor.success)
                }
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(IMColor.brand.opacity(0.10)))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.86))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(IMColor.brand.opacity(!hasConversation ? 0.10 : 0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("start_direct_chat_contact_\(userID)")
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

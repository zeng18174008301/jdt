// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct FindUserContent<Row: View>: View {
    @Binding var keyword: String
    @Binding var applyMessage: String
    let hint: String?
    let results: [UserSearchResult]
    let hasSearched: Bool
    let isSearching: Bool
    let onSearch: () -> Void
    let onClear: () -> Void
    let onClose: () -> Void
    let row: (UserSearchResult) -> Row

    public init(keyword: Binding<String>, applyMessage: Binding<String>, hint: String?, results: [UserSearchResult],
                hasSearched: Bool, isSearching: Bool, onSearch: @escaping () -> Void, onClear: @escaping () -> Void,
                onClose: @escaping () -> Void, @ViewBuilder row: @escaping (UserSearchResult) -> Row) {
        _keyword = keyword
        _applyMessage = applyMessage
        self.hint = hint
        self.results = results
        self.hasSearched = hasSearched
        self.isSearching = isSearching
        self.onSearch = onSearch
        self.onClear = onClear
        self.onClose = onClose
        self.row = row
    }

    public var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 14) {
                    ConversationQuickSheetHeader(
                        symbol: "person.text.rectangle.fill",
                        title: "查找用户",
                        subtitle: "输入用户ID的纯数字部分，查找当前企业用户。",
                        onClose: onClose
                    )

                    // WDT_CHAT_FIX4_USER_ID_HINT_20261023
                    if let hint {
                        Text(hint)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(IMColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("find_user_own_id_hint")
                    }

                    searchInput

                    VStack(alignment: .leading, spacing: 8) {
                        Text("申请备注")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                        TextField("输入好友申请备注", text: $applyMessage)
                            .font(.system(size: 14, weight: .semibold))
                            .textInputAutocapitalization(.never)
                            .im4ImReadableInputText()
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.92)))
                            .accessibilityIdentifier("find_user_apply_message_input")
                    }
                    .im4PlainCard(radius: 22)

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            if isSearching {
                                ProgressView("正在搜索")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                                    .im4PlainCard(radius: 24)
                            } else if !hasSearched {
                                EmptyStateView(
                                    symbol: "person.crop.circle.badge.questionmark",
                                    title: "输入用户ID的纯数字部分",
                                    subtitle: "仅搜索当前企业内可见用户，搜索不到时不会生成任何本地结果。"
                                )
                            } else if results.isEmpty {
                                EmptyStateView(
                                    symbol: "magnifyingglass",
                                    title: "未找到用户",
                                    subtitle: "请确认用户ID的数字部分是否正确，或该用户是否属于当前企业。"
                                )
                            } else {
                                ForEach(results) { item in
                                    row(item)
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
                .padding(18)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { onClose() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColor.brand)
                        .accessibilityIdentifier("find_user_close_button")
                }
            }
        }
    }

    private var searchInput: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(IMColor.muted)
            TextField("用户ID的纯数字部分", text: $keyword)
                .font(.system(size: 15, weight: .bold))
                .im4ImReadableInputText()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { onSearch() }
                .accessibilityIdentifier("find_user_search_input")
            if !keyword.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.muted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("find_user_clear_button")
            }
            Button {
                onSearch()
            } label: {
                Text("搜索")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(IMColor.brand))
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .opacity(isSearching ? 0.55 : 1)
            .accessibilityIdentifier("find_user_search_button")
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(IMColor.line.opacity(0.8), lineWidth: 1)
                )
        )
    }

}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct ConversationListScreenContent<Table: View>: View {
    let table: Table

    public init(@ViewBuilder table: () -> Table) { self.table = table() }

    public var body: some View {
        ZStack {
            AuroraBackground()
            table
        }
        .overlay(alignment: .top) {
            PinnedSearchTopMask()
        }
    }
}

public struct ConversationListFooterContent<Search: View, Mentions: View>: View {
    let isGlobalSearchActive: Bool
    let isInitialLoading: Bool
    let syncFailureMessage: String?
    let isSyncRetrying: Bool
    let isLoadingMoreConversations: Bool
    let isConversationSnapshotPartial: Bool
    let hasConversations: Bool
    let matchesAreEmpty: Bool
    let queryIsEmpty: Bool
    let filter: String
    let search: () -> Search
    let mentions: () -> Mentions
    let onRetry: () -> Void
    let onClear: () -> Void

    public init(isGlobalSearchActive: Bool, isInitialLoading: Bool, syncFailureMessage: String?,
                isSyncRetrying: Bool, isLoadingMoreConversations: Bool, isConversationSnapshotPartial: Bool,
                hasConversations: Bool, matchesAreEmpty: Bool, queryIsEmpty: Bool, filter: String,
                @ViewBuilder search: @escaping () -> Search, @ViewBuilder mentions: @escaping () -> Mentions,
                onRetry: @escaping () -> Void, onClear: @escaping () -> Void) {
        self.isGlobalSearchActive = isGlobalSearchActive
        self.isInitialLoading = isInitialLoading
        self.syncFailureMessage = syncFailureMessage
        self.isSyncRetrying = isSyncRetrying
        self.isLoadingMoreConversations = isLoadingMoreConversations
        self.isConversationSnapshotPartial = isConversationSnapshotPartial
        self.hasConversations = hasConversations
        self.matchesAreEmpty = matchesAreEmpty
        self.queryIsEmpty = queryIsEmpty
        self.filter = filter
        self.search = search
        self.mentions = mentions
        self.onRetry = onRetry
        self.onClear = onClear
    }

    public var body: some View {
        if isGlobalSearchActive {
            search()
                .padding(.horizontal, 18)
        } else if isInitialLoading && !hasConversations && filter != "@我" { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            RemoteLoadingStateView(
                title: "正在同步会话",
                subtitle: "登录成功，正在立即拉取真实会话和最近消息。"
            )
            .padding(.horizontal, 18)
        } else if let syncFailureMessage = syncFailureMessage, !hasConversations, filter != "@我" { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            EmptyStateView(
                symbol: "arrow.clockwise.icloud",
                title: "聊天数据同步失败",
                subtitle: syncFailureMessage,
                actionTitle: isSyncRetrying ? "正在重试..." : "重试同步" // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            ) {
                onRetry()
            }
            .padding(.horizontal, 18)
        } else if filter == "@我" {
            mentions()
                .padding(.horizontal, 18)
        } else if matchesAreEmpty {
            let isUnfilteredEmpty = queryIsEmpty && filter == "全部"
            EmptyStateView(
                symbol: "bubble.left",
                title: isUnfilteredEmpty ? "暂无会话" : "没有匹配会话",
                subtitle: isUnfilteredEmpty ? "当前账号暂未返回可见会话。" : "换个关键词，或切换筛选条件查看全部会话。"
            ) {
                onClear()
            }
            .padding(.horizontal, 18)
        }
        if !isGlobalSearchActive, filter != "@我", hasConversations {
            if isLoadingMoreConversations { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                HStack {
                    ProgressView()
                    Text("正在加载更多会话…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isConversationSnapshotPartial { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                Button("部分会话尚未加载，点击重试") { onRetry() }
                    .font(.caption)
                    .disabled(isSyncRetrying) // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            }
        }
        Color.clear.frame(height: 12)
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

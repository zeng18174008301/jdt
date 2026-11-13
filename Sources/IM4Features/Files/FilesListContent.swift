// WDT_IOS1_FEATURES_FILES_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct FilesListContent<Rows: View>: View {
    @Binding var query: String
    @Binding var type: String
    let types: [String]
    let isRefreshing: Bool
    let errorMessage: String?
    let hasCachedFiles: Bool
    let lastRefreshedAt: Date?
    let isInitialLoading: Bool
    let isEmpty: Bool
    let emptySymbol: String
    let emptyTitle: String
    let emptySubtitle: String
    let retry: () -> Void
    let retrySync: () -> Void
    let refresh: () async -> Void
    let rows: () -> Rows
    public init(query: Binding<String>, type: Binding<String>, types: [String], isRefreshing: Bool,
                errorMessage: String?, hasCachedFiles: Bool, lastRefreshedAt: Date?, isInitialLoading: Bool,
                isEmpty: Bool, emptySymbol: String, emptyTitle: String, emptySubtitle: String,
                retry: @escaping () -> Void, retrySync: @escaping () -> Void, refresh: @escaping () async -> Void,
                @ViewBuilder rows: @escaping () -> Rows) {
        _query = query; _type = type; self.types = types; self.isRefreshing = isRefreshing; self.errorMessage = errorMessage
        self.hasCachedFiles = hasCachedFiles; self.lastRefreshedAt = lastRefreshedAt; self.isInitialLoading = isInitialLoading
        self.isEmpty = isEmpty; self.emptySymbol = emptySymbol; self.emptyTitle = emptyTitle; self.emptySubtitle = emptySubtitle
        self.retry = retry; self.retrySync = retrySync; self.refresh = refresh; self.rows = rows
    }
    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            typeBar
                            FileRefreshHintView(isRefreshing: isRefreshing, errorMessage: errorMessage,
                                hasCachedFiles: hasCachedFiles, lastRefreshedAt: lastRefreshedAt, retry: retry)
                            if isInitialLoading && !hasCachedFiles && query.isEmpty {
                                RemoteLoadingStateView(title: "正在加载收藏资料", subtitle: "正在拉取你收藏的图片、视频和文件。")
                            } else if let errorMessage, !hasCachedFiles {
                                EmptyStateView(symbol: "wifi.exclamationmark", title: "资料加载失败", subtitle: errorMessage)
                                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise", action: retrySync)
                            } else if isEmpty {
                                EmptyStateView(symbol: emptySymbol, title: emptyTitle, subtitle: emptySubtitle)
                            } else {
                                rows()
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                    } header: {
                        PinnedSearchHeader {
                            SearchField(text: $query, placeholder: "搜索文件、来源、发送人", onSearch: retrySync)
                        }
                    }
                }
            }
            .refreshable { await refresh() }
        }
        .overlay(alignment: .top) { PinnedSearchTopMask() }
    }
    private var typeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(types, id: \.self) { item in
                    Button { type = item } label: { Chip(title: item, isSelected: type == item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}
// WDT_IOS1_FEATURES_FILES_UI_20261111_END

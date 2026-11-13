import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

// WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
enum ChatSearchDatePurpose: String, Identifiable {
    case jump, filter
    var id: Self { self }
    var title: String { self == .jump ? "按日期跳转" : "按日期筛选" }
    var actionTitle: String { self == .jump ? "跳转到这一天" : "应用日期筛选" }

    init(keyword: String) {
        self = keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .jump : .filter
    }
}

// WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
public struct ChatHistorySearchPanel: View {
    @Environment(\.chatRenderingShowsMessageProcessingNotices) private var showsNotices // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    @Binding var keyword: String
    @Binding var dateText: String
    let results: [ChatHistorySearchResultPresentation]
    let visibleResults: [ChatHistorySearchResultPresentation]
    let total: Int
    let hitChannelSeqs: [Int64]
    let isSearching: Bool
    let isLoadingMore: Bool
    let hasMore: Bool
    let searchFocus: Binding<Bool> // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113
    let onSearch: () -> Void
    let onDateSearch: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLoadMore: () -> Void
    let onClose: () -> Void
    let onSelect: (ChatHistorySearchResultPresentation) -> Void
    let onQueryChange: () -> Void
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    let retainedQuery: String?
    let failureMessage: String?
    let pageFailureMessage: String?
    let coverageMessage: String?
    let onRetry: (() -> Void)?
    let onPageRetry: (() -> Void)?
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
    private let messagesOnly: Binding<Bool>? // WDT_IOS1_SEARCH_CURSOR_V2_20261113
    private let hasCurrentResponse: Bool // WDT_IOS1_SEARCH_CURSOR_V2_20261113
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    private let fullScreen: Bool
    private let extraFilters: AnyView?
    private let recent: [String]
    private let onRecent: (String) -> Void
    private let onRemoveRecent: (String) -> Void
    private let onClearRecent: () -> Void
    private let automaticPageRevision: UInt64?
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    private let filterDate: Date?
    private let onFilterDate: (Date?) -> Void
    private let dateAvailabilityRevision: UInt64
    private let loadAvailableDates: (Date, Calendar) async -> Set<Date>
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    @State private var datePicker: ChatSearchDatePurpose?
    @State private var jumpAfterDatePicker = false
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END

    private var trimmedDateText: String {
        dateText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    private var canSubmit: Bool {
        !isSearching && !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    private var selectedDateLabel: String {
        guard let date = chatSearchDate(from: trimmedDateText) else {
            return "按日期跳转"
        }
        return chatSearchDisplayDate(date)
    }

    private var selectedDateSubtitle: String {
        trimmedDateText.isEmpty ? "选择某天的聊天记录" : trimmedDateText
    }

    private var searchQueryControls: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_BEGIN
                CommittedSearchInput(
                    text: $keyword,
                    placeholder: "搜索历史聊天记录",
                    focus: searchFocus,
                    font: .systemFont(ofSize: 14, weight: .semibold),
                    onSubmit: onSearch
                )
                // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113_END
                    .im4OnChangeCompat(of: keyword) { _, _ in
                        onQueryChange()
                    }
                    .accessibilityIdentifier("chat_search_input")
                    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
                    .frame(height: 36)
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(IMColor.muted.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onSearch) {
                    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
                    Text("搜索")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(canSubmit ? IMColor.brand : IMColor.muted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityIdentifier("chat_search_submit_button")
                if !fullScreen {
                    Button(action: onClose) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(IMColor.page.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat_search_close_button")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.96)))

    }

    private var fullScreenFilters: some View {
        HStack(spacing: 8) {
            if let extraFilters { extraFilters }
            Button {
                searchFocus.wrappedValue = false
                datePicker = ChatSearchDatePurpose(keyword: keyword)
            } label: {
                Label(filterDate.map(chatSearchDisplayDate) ?? "日期", systemImage: "calendar")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(filterDate == nil ? IMColor.ink : IMColor.brand)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 38)
                    .background(Capsule().fill(filterDate == nil ? .white.opacity(0.92) : IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(filterDate.map { "日期，已筛选\(chatSearchDisplayDate($0))" } ?? "日期")
            .accessibilityIdentifier("chat_search_date_picker_button")
            Spacer(minLength: 0)
            if total > 0 {
                Text("共 \(max(total, results.count)) 条")
                    .font(.caption)
                    .foregroundStyle(IMColor.muted)
                    .monospacedDigit()
            }
        }
    }

    private var searchDateControls: some View {
            HStack(spacing: 8) {
                Button {
                    searchFocus.wrappedValue = false
                    datePicker = .jump
                    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.brand)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(IMColor.brand.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedDateLabel)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(IMColor.ink)
                                .lineLimit(1)
                            Text(selectedDateSubtitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(trimmedDateText.isEmpty ? IMColor.muted : IMColor.brand)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(IMColor.muted)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .frame(height: 38)
                    .background(Capsule().fill(.white.opacity(0.92)))
                    .overlay(Capsule().stroke(trimmedDateText.isEmpty ? IMColor.line : IMColor.brand.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isSearching)
                .accessibilityIdentifier("chat_search_date_picker_button")

                Button(action: onDateSearch) {
                    Text("跳转")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(trimmedDateText.isEmpty ? IMColor.muted.opacity(0.45) : IMColor.brand))
                }
                .buttonStyle(.plain)
                .disabled(isSearching || trimmedDateText.isEmpty)
                .accessibilityIdentifier("chat_search_date_jump_button")
                Spacer(minLength: 8)
                if total > 0 || (!fullScreen && !hitChannelSeqs.isEmpty) {
                    Text("共 \(max(total, results.count)) 条")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .monospacedDigit()
                }
                if !fullScreen { // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.white.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                    .disabled(results.isEmpty)
                    Button(action: onNext) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.white.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                    .disabled(results.isEmpty)
                }
            }
            .padding(.horizontal, 2)

    }

    public var body: some View {
        VStack(spacing: 10) {
            searchQueryControls
            // WDT_IOS1_SEARCH_CURSOR_V2_20261113_BEGIN
            if let messagesOnly {
                Picker("搜索范围", selection: messagesOnly) {
                    Text("全部").tag(false)
                    Text("聊天记录").tag(true)
                }
                .pickerStyle(.segmented)
                .im4OnChangeCompat(of: messagesOnly.wrappedValue) { _, _ in onQueryChange() }
            }
            // WDT_IOS1_SEARCH_CURSOR_V2_20261113_END
            // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
            if fullScreen {
                fullScreenFilters
            } else {
                searchDateControls
                if let extraFilters { extraFilters }
            }
            // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
            if let failureMessage { searchNotice(failureMessage, retry: onRetry) }
            if let retainedQuery { searchNotice("上次搜索：\(retainedQuery)") }
            if retainedQuery == nil, let coverageMessage { searchNotice(coverageMessage) }
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(IMColor.brand)
                    Text("正在搜索聊天记录")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            if !visibleResults.isEmpty || (hasMore && hasCurrentResponse) { // WDT_IOS1_SEARCH_CURSOR_V2_20261113
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleResults, id: \.id) { hit in // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                            Button {
                                onSelect(hit)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(hit.displayKind ?? (hit.type == "file" || hit.type == "files" ? "文件" : "聊天记录")) // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
                                            .font(.system(size: 11, weight: .black))
                                            .foregroundStyle(IMColor.muted)
                                            .lineLimit(1)
                                        hit.highlightedPreview // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(IMColor.ink)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 8)
                                    Text(hit.subtitle ?? "")
                                        .font(.system(size: 11, weight: .black))
                                        .foregroundStyle(IMColor.muted)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                            }
                            .buttonStyle(.plain)
                            .disabled(retainedQuery != nil || isSearching) // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
                            .accessibilityIdentifier("chat_search_result_\(hit.type)_\(hit.resultID)")
                            .accessibilityLabel("聊天搜索结果 \(hit.title)")
                        }
                        if hasMore && retainedQuery == nil && pageFailureMessage == nil { // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
                            Button(action: onLoadMore) {
                                HStack(spacing: 8) {
                                    if isLoadingMore {
                                        ProgressView()
                                            .tint(IMColor.brand)
                                    }
                                    Text(isLoadingMore ? "正在加载" : "加载更多")
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(IMColor.brand)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMore || isSearching) // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
                            .id(automaticPageRevision) // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                            .onAppear { if automaticPageRevision != nil && !isSearching { onLoadMore() } } // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: fullScreen ? .infinity : 238) // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
            } else if hasCurrentResponse, failureMessage == nil, coverageMessage == nil, !isSearching,
                      !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("没有找到相关聊天记录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if let pageFailureMessage { searchNotice(pageFailureMessage, retry: onPageRetry) }
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
            // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
            if fullScreen && keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSearching {
                recentSearches
            }
            if fullScreen && visibleResults.isEmpty && !(hasMore && hasCurrentResponse) { Spacer(minLength: 0) }
            // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        }
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        .padding(fullScreen ? 16 : 10)
        .frame(maxHeight: fullScreen ? .infinity : nil, alignment: .top)
        .background {
            if fullScreen {
                AuroraBackground()
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.72))
            }
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocus.wrappedValue = !fullScreen
            if !fullScreen && !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onQueryChange()
            }
        }
        .sheet(item: $datePicker, onDismiss: {
            guard jumpAfterDatePicker else { return }
            jumpAfterDatePicker = false
            onDateSearch()
        }) { purpose in
            ChatSearchDatePickerSheet(
                purpose: purpose,
                initialDate: filterDate ?? (purpose == .jump ? chatSearchDate(from: dateText) : nil),
                revision: dateAvailabilityRevision,
                loadAvailableDates: loadAvailableDates,
                onCancel: { datePicker = nil },
                onClear: filterDate != nil ? {
                    onFilterDate(nil)
                    datePicker = nil
                } : nil,
                onApply: { date in
                    if purpose == .jump {
                        dateText = chatSearchAPIDate(date)
                        jumpAfterDatePicker = true
                    } else {
                        onFilterDate(date)
                    }
                    datePicker = nil
                }
            )
            .im4PresentationDetentsCompat([.large])
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        }
    }

    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近搜索").font(.subheadline.weight(.semibold))
                Spacer()
                if !recent.isEmpty { Button("清空", action: onClearRecent) }
            }
            if recent.isEmpty {
                Text("输入关键词查找当前会话的聊天记录或文件")
                    .font(.footnote)
                    .foregroundStyle(IMColor.muted)
            } else {
                ScrollView {
                    LazyVStack {
                        ForEach(recent, id: \.self) { term in
                            HStack {
                                Button { onRecent(term) } label: {
                                    Label(term, systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button { onRemoveRecent(term) } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("删除 \(term)")
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .padding(12)
    }
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END

    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    private func searchNotice(_ message: String, retry: (() -> Void)? = nil) -> some View {
        HStack {
            Text(message).font(.subheadline).foregroundStyle(IMColor.muted)
            Spacer()
            if let retry { Button("重试", action: retry).buttonStyle(.borderless) }
        }
        .padding(.horizontal, 12)
    }
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

    public init(keyword: Binding<String>,
        dateText: Binding<String>,
        results: [ChatHistorySearchResultPresentation],
        visibleResults: [ChatHistorySearchResultPresentation],
        total: Int,
        hitChannelSeqs: [Int64],
        isSearching: Bool,
        isLoadingMore: Bool,
        hasMore: Bool,
        searchFocus: Binding<Bool>, // WDT_IOS1_SEARCH_COMMITTED_INPUT_20261113
        onSearch: @escaping () -> Void,
        onDateSearch: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSelect: @escaping (ChatHistorySearchResultPresentation) -> Void,
        onQueryChange: @escaping () -> Void,
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        retainedQuery: String? = nil,
        failureMessage: String? = nil,
        pageFailureMessage: String? = nil,
        coverageMessage: String? = nil,
        onRetry: (() -> Void)? = nil,
        onPageRetry: (() -> Void)? = nil,
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        // WDT_IOS1_SEARCH_CURSOR_V2_20261113_BEGIN
        messagesOnly: Binding<Bool>? = nil,
        hasCurrentResponse: Bool = false,
        // WDT_IOS1_SEARCH_CURSOR_V2_20261113_END
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        fullScreen: Bool = false,
        extraFilters: AnyView? = nil,
        recent: [String] = [],
        onRecent: @escaping (String) -> Void = { _ in },
        onRemoveRecent: @escaping (String) -> Void = { _ in },
        onClearRecent: @escaping () -> Void = {},
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        automaticPageRevision: UInt64? = nil,
        filterDate: Date? = nil,
        onFilterDate: @escaping (Date?) -> Void = { _ in },
        dateAvailabilityRevision: UInt64 = 0,
        loadAvailableDates: @escaping (Date, Calendar) async -> Set<Date> = { _, _ in [] }
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    ) {
        self._keyword = keyword
        self._dateText = dateText
        self.results = results
        self.visibleResults = visibleResults
        self.total = total
        self.hitChannelSeqs = hitChannelSeqs
        self.isSearching = isSearching
        self.isLoadingMore = isLoadingMore
        self.hasMore = hasMore
        self.searchFocus = searchFocus
        self.onSearch = onSearch
        self.onDateSearch = onDateSearch
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onLoadMore = onLoadMore
        self.onClose = onClose
        self.onSelect = onSelect
        self.onQueryChange = onQueryChange
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        self.retainedQuery = retainedQuery
        self.failureMessage = failureMessage
        self.pageFailureMessage = pageFailureMessage
        self.coverageMessage = coverageMessage
        self.onRetry = onRetry
        self.onPageRetry = onPageRetry
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        self.messagesOnly = messagesOnly // WDT_IOS1_SEARCH_CURSOR_V2_20261113
        self.hasCurrentResponse = hasCurrentResponse // WDT_IOS1_SEARCH_CURSOR_V2_20261113
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        self.fullScreen = fullScreen
        self.extraFilters = extraFilters
        self.recent = recent
        self.onRecent = onRecent
        self.onRemoveRecent = onRemoveRecent
        self.onClearRecent = onClearRecent
        self.automaticPageRevision = automaticPageRevision
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        self.filterDate = filterDate
        self.onFilterDate = onFilterDate
        self.dateAvailabilityRevision = dateAvailabilityRevision
        self.loadAvailableDates = loadAvailableDates
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    }
}

private struct ChatSearchDatePickerSheet: View {
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    let purpose: ChatSearchDatePurpose
    let revision: UInt64
    let loadAvailableDates: (Date, Calendar) async -> Set<Date>
    let onCancel: () -> Void
    let onClear: (() -> Void)?
    let onApply: (Date) -> Void

    @State private var visibleMonth: Date
    @State private var selectedDate: Date?
    @State private var loaded: MonthRequest?
    @State private var availableDates: Set<Date> = []

    private struct MonthRequest: Equatable {
        let month: Date
        let revision: UInt64
    }

    init(purpose: ChatSearchDatePurpose, initialDate: Date?, revision: UInt64,
         loadAvailableDates: @escaping (Date, Calendar) async -> Set<Date>,
         onCancel: @escaping () -> Void, onClear: (() -> Void)?, onApply: @escaping (Date) -> Void) {
        self.purpose = purpose
        self.revision = revision
        self.loadAvailableDates = loadAvailableDates
        self.onCancel = onCancel
        self.onClear = onClear
        self.onApply = onApply
        _visibleMonth = State(initialValue: ChatSearchCalendarSupport.startOfMonth(initialDate ?? Date()))
        _selectedDate = State(initialValue: initialDate.map(ChatSearchCalendarSupport.startOfDay))
    }

    private var request: MonthRequest { MonthRequest(month: visibleMonth, revision: revision) }
    private var dates: Set<Date> { loaded == request ? availableDates : [] }
    private var selectedAvailableDate: Date? { selectedDate.flatMap { dates.contains($0) ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(purpose.title).font(.headline).foregroundStyle(IMColor.ink)
                Spacer()
                Button("取消", action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IMColor.brand)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ChatSearchGregorianCalendarView(selectedDate: $selectedDate, visibleMonth: $visibleMonth,
                        maximumDate: Date(), availableDates: dates)
                    if loaded != request {
                        HStack(spacing: 8) {
                            ProgressView().tint(IMColor.brand)
                            Text("正在核对可选日期")
                        }
                        .font(.footnote)
                        .foregroundStyle(IMColor.muted)
                    } else {
                        Text(dates.isEmpty ? "本月暂无已同步的可选日期" : "仅显示本机已同步的可见聊天记录")
                            .font(.footnote)
                            .foregroundStyle(IMColor.muted)
                    }
                }
                .padding(20)
            }

            HStack(spacing: 12) {
                if let onClear {
                    Button("清除筛选", action: onClear)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IMColor.brand)
                        .frame(minHeight: 48)
                }
                Button {
                    if let selectedAvailableDate { onApply(selectedAvailableDate) }
                } label: {
                    Text(purpose.actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 14).fill(IMColor.brand))
                        .opacity(selectedAvailableDate == nil ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(selectedAvailableDate == nil)
                .accessibilityIdentifier("chat_search_calendar_apply")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background { AuroraBackground() }
        .task(id: request) {
            let requested = request
            let available = await loadAvailableDates(requested.month, ChatSearchCalendarSupport.calendar)
            guard !Task.isCancelled else { return }
            availableDates = available
            loaded = requested
            if let selectedDate, !available.contains(selectedDate) { self.selectedDate = nil }
        }
    }
}

private struct ChatSearchGregorianCalendarView: View {
    @Binding var selectedDate: Date?
    @Binding var visibleMonth: Date
    let maximumDate: Date
    let availableDates: Set<Date>

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var cells: [ChatSearchCalendarDay] {
        ChatSearchCalendarSupport.dayCells(for: visibleMonth, selectedDate: selectedDate,
            today: maximumDate, availableDates: availableDates)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(ChatSearchCalendarSupport.monthTitle(for: visibleMonth))
                    .font(.headline)
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Spacer()
                monthButton("chevron.left", label: "上个月", offset: -1)
                monthButton("chevron.right", label: "下个月", offset: 1)
                    .disabled(!ChatSearchCalendarSupport.canMoveToNextMonth(from: visibleMonth, maximumDate: maximumDate))
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(ChatSearchCalendarSupport.weekdaySymbols, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                }
                ForEach(cells) { cell in
                    if cell.isInDisplayedMonth {
                        Button { selectedDate = cell.date } label: {
                            Text("\(cell.day)")
                                .font(.subheadline.weight(cell.isAvailable ? .semibold : .regular))
                                .foregroundStyle(cell.isSelected ? .white : cell.isAvailable ? IMColor.ink : IMColor.muted.opacity(0.55))
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    Circle()
                                        .fill(cell.isSelected ? IMColor.brand : cell.isAvailable ? IMColor.brand.opacity(0.10) : .clear)
                                        .frame(width: 34, height: 34)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!cell.isAvailable)
                        .accessibilityLabel(ChatSearchCalendarSupport.displayDate(cell.date))
                        .accessibilityIdentifier("chat_search_calendar_day_\(cell.id)")
                    } else {
                        Color.clear.frame(height: 42).accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.94)))
        .accessibilityIdentifier("chat_search_gregorian_calendar")
    }

    private func monthButton(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            selectedDate = nil
            visibleMonth = ChatSearchCalendarSupport.addingMonths(offset, to: visibleMonth)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IMColor.brand)
                .frame(width: 44, height: 44)
                .background(Circle().fill(IMColor.page))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    }
}

struct ChatSearchCalendarDay: Identifiable, Equatable {
    let id: String
    let date: Date
    let day: Int
    let isInDisplayedMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let isFuture: Bool
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
    let isAvailable: Bool
}

enum ChatSearchCalendarSupport {
    static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func date(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func startOfMonth(_ date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? startOfDay(date)
    }

    static func addingDays(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: value, to: date) ?? date
    }

    static func addingMonths(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: value, to: startOfMonth(date)) ?? date
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func monthTitle(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 1970)年\(components.month ?? 1)月"
    }

    static func apiDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    static func displayDate(_ date: Date) -> String {
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let components = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekday = weekdays[max(0, min((components.weekday ?? 1) - 1, weekdays.count - 1))]
        return "\(components.month ?? 1)月\(components.day ?? 1)日 \(weekday)"
    }

    static func canMoveToNextMonth(from month: Date, maximumDate: Date) -> Bool {
        let nextMonth = addingMonths(1, to: month)
        return calendar.compare(nextMonth, to: startOfMonth(maximumDate), toGranularity: .month) != .orderedDescending
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    static func dayCells(for displayedMonth: Date, selectedDate: Date?, today: Date,
                         availableDates: Set<Date>? = nil) -> [ChatSearchCalendarDay] {
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        let monthStart = startOfMonth(displayedMonth)
        let monthComponents = calendar.dateComponents([.year, .month], from: monthStart)
        let leadingDays = max(0, calendar.component(.weekday, from: monthStart) - 1)
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        let todayStart = startOfDay(today)

        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: gridStart) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            let dayStart = startOfDay(date)
            let isInDisplayedMonth = components.year == monthComponents.year && components.month == monthComponents.month
            // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
            let isFuture = dayStart > todayStart
            let isAvailable = isInDisplayedMonth && !isFuture && (availableDates?.contains(dayStart) ?? true)
            // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
            return ChatSearchCalendarDay(
                id: apiDate(date),
                date: date,
                day: components.day ?? 1,
                isInDisplayedMonth: isInDisplayedMonth,
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
                isSelected: isAvailable && selectedDate.map { isSameDay(date, $0) } == true,
                isToday: isSameDay(date, today),
                isFuture: isFuture,
                isAvailable: isAvailable
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
            )
        }
    }
}

private func chatSearchDate(from text: String) -> Date? {
    let parts = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "-")
        .compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let components = DateComponents(calendar: calendar, timeZone: .current, year: parts[0], month: parts[1], day: parts[2])
    guard let date = components.date else { return nil }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    guard resolved.year == parts[0], resolved.month == parts[1], resolved.day == parts[2] else { return nil }
    return date
}

private func chatSearchAPIDate(_ date: Date) -> String {
    ChatSearchCalendarSupport.apiDate(date)
}

private func chatSearchDisplayDate(_ date: Date) -> String {
    ChatSearchCalendarSupport.displayDate(date)
}

// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

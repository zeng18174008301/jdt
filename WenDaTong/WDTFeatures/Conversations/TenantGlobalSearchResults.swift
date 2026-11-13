import SwiftUI

// WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
enum TenantGlobalSearchCategory: String, CaseIterable, Identifiable {
    case contacts, groups, conversations, messages, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contacts: return "联系人"
        case .groups: return "群聊"
        case .conversations: return "会话"
        case .messages: return "聊天记录"
        case .files: return "文件"
        }
    }

    var icon: String {
        switch self {
        case .contacts: return "person.crop.circle"
        case .groups: return "person.3.fill"
        case .conversations: return "bubble.left.and.bubble.right.fill"
        case .messages: return "text.bubble.fill"
        case .files: return "doc.fill"
        }
    }
}

struct TenantGlobalSearchKey: Hashable {
    let query: String
    let category: TenantGlobalSearchCategory?

    var types: [TenantGlobalSearchCategory] {
        category.map { [$0] } ?? TenantGlobalSearchCategory.allCases
    }
}

enum TenantGlobalSearchCursor: Hashable {
    case v2(String)
    case legacy(String)

    init?(bucket: RemoteTenantSearchBucket, category: TenantGlobalSearchCategory) {
        if category == .messages, let cursor = bucket.nextCursorV2, !cursor.isEmpty {
            self = .v2(cursor)
        } else if let cursor = bucket.nextCursor, !cursor.isEmpty {
            self = .legacy(cursor)
        } else {
            return nil
        }
    }

    var legacy: String? {
        if case .legacy(let value) = self { return value }
        return nil
    }

    var v2: String? {
        if case .v2(let value) = self { return value }
        return nil
    }
}

struct TenantGlobalSearchAnalyticsContext {
    let searchID: String?
    let requestID: String?
    let elapsedMS: Int?
    let filters: [String: String]

    init(_ response: RemoteTenantSearchResponse) {
        searchID = response.searchID
        requestID = response.requestID
        elapsedMS = response.elapsedMS
        let pairs = response.parsedFilters.map { ($0.key.isEmpty ? $0.type : $0.key, $0.value) }
        filters = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}

struct TenantGlobalSearchPageData {
    let key: TenantGlobalSearchKey
    var response: RemoteTenantSearchResponse
    var consumedCursors: Set<TenantGlobalSearchCursor> = []
    var pageFailure: TenantSearchFailure?
    var conversationIDs: Set<String> = []
    private var analyticsByResultID: [String: TenantGlobalSearchAnalyticsContext] = [:]

    init(key: TenantGlobalSearchKey, response: RemoteTenantSearchResponse) {
        self.key = key
        self.response = response
        attributeResults(from: response)
    }

    mutating func append(_ next: RemoteTenantSearchResponse, type: String, cursor: TenantGlobalSearchCursor) {
        attributeResults(from: next)
        response = mergedGlobalSearchResponse(current: response, next: next, appendingType: type)
        consumedCursors.insert(cursor)
    }

    func analytics(for id: String) -> TenantGlobalSearchAnalyticsContext? {
        analyticsByResultID[id]
    }

    private mutating func attributeResults(from response: RemoteTenantSearchResponse) {
        let context = TenantGlobalSearchAnalyticsContext(response)
        for bucket in response.resultsByType.values {
            for item in bucket.items { analyticsByResultID[item.id] = context }
        }
    }

    var nextCursor: TenantGlobalSearchCursor? {
        guard let category = key.category, let bucket = response.resultsByType[category.rawValue], bucket.hasMore,
              let cursor = TenantGlobalSearchCursor(bucket: bucket, category: category),
              !consumedCursors.contains(cursor) else { return nil }
        return cursor
    }
}

struct TenantGlobalSearchRow: Identifiable {
    let item: RemoteTenantSearchResult
    let display: TenantSearchResultDisplayModel
    let contactName: String?
    let contactUID: String?
    let conversationID: String?

    var id: String { item.id }

    static func contactExactUID(for item: RemoteTenantSearchResult) -> String? { // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110
        let normalizedType = item.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["contact", "contacts"].contains(normalizedType) else {
            return nil
        }
        return [
            item.jumpTarget?.imUID,
            item.jumpTarget?.peerIMUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }
}

struct TenantGlobalSearchProjection {
    var rows: [TenantGlobalSearchCategory: [TenantGlobalSearchRow]] = [:]
    var conversationIDs: Set<String> = []

    func row(id: String, for key: TenantGlobalSearchKey) -> TenantGlobalSearchRow? {
        for type in key.types {
            if let match = rows[type]?.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}

private func mergedGlobalSearchResponse(
    current: RemoteTenantSearchResponse,
    next: RemoteTenantSearchResponse,
    appendingType type: String
) -> RemoteTenantSearchResponse {
    var buckets = current.resultsByType
    let currentBucket = current.resultsByType[type] ?? RemoteTenantSearchBucket(items: [])
    let nextBucket = next.resultsByType[type] ?? RemoteTenantSearchBucket(items: [])
    let mergedItems = stableMergedSearchItems(currentBucket.items, appending: nextBucket.items)
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    buckets[type] = RemoteTenantSearchBucket(
        items: mergedItems,
        count: nextBucket.exactTotal ?? mergedItems.count,
        hasMore: nextBucket.hasMore,
        nextCursor: nextBucket.nextCursor,
        nextCursorV2: nextBucket.nextCursorV2,
        totalIsExact: nextBucket.totalIsExact,
        status: nextBucket.status,
        authoritative: nextBucket.authoritative,
        error: nextBucket.error
    )
    var bucketErrors = current.errorsByType
    bucketErrors[type] = next.errorsByType[type] ?? nextBucket.error
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
    return RemoteTenantSearchResponse(
        query: next.query.isEmpty ? current.query : next.query,
        scope: next.scope.isEmpty ? current.scope : next.scope,
        types: current.types,
        limit: next.limit,
        searchID: next.searchID ?? current.searchID,
        requestID: next.requestID ?? current.requestID,
        elapsedMS: next.elapsedMS,
        resultsByType: buckets,
        degraded: next.degraded || !bucketErrors.isEmpty, // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
        errorsByType: bucketErrors, // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113
        items: stableMergedSearchItems(current.items, appending: next.items),
        compatibility: next.compatibility.isEmpty ? current.compatibility : next.compatibility,
        analytics: next.analytics.isEmpty ? current.analytics : next.analytics,
        parsedFilters: next.parsedFilters.isEmpty ? current.parsedFilters : next.parsedFilters,
        conversationSearch: next.conversationSearch ?? current.conversationSearch,
        conversationDateAnchor: next.conversationDateAnchor ?? current.conversationDateAnchor
    )
}

private func stableMergedSearchItems(
    _ existing: [RemoteTenantSearchResult],
    appending incoming: [RemoteTenantSearchResult]
) -> [RemoteTenantSearchResult] {
    var indexByID: [String: Int] = [:]
    var result = existing
    for (index, item) in existing.enumerated() {
        indexByID[item.id] = index
    }
    for item in incoming {
        if let index = indexByID[item.id] {
            result[index] = item
        } else {
            indexByID[item.id] = result.count
            result.append(item)
        }
    }
    return result
}


func globalSearchCoverage(
    _ response: RemoteTenantSearchResponse, category: TenantGlobalSearchCategory
) -> String? {
    let type = category.rawValue
    let bucket = response.resultsByType[type]
    if let error = bucket?.error ?? response.errorsByType[type], error.code == "query_too_short" {
        return "聊天记录需要至少 2 个字"
    }
    if bucket?.status == "unavailable" || bucket == nil {
        return "\(category.title)暂时无法搜索"
    }
    if bucket?.error != nil || response.errorsByType[type] != nil || bucket?.authoritative == false
        || (category != .messages && bucket?.totalIsExact == false) {
        return "\(category.title)仅显示部分结果"
    }
    return nil
}

struct TenantGlobalSearchRecentView: View {
    let terms: [String]
    let onSelect: (String) -> Void
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_BEGIN
        VStack(alignment: .leading, spacing: 8) {
            if !terms.isEmpty {
                HStack {
                    Text("最近搜索")
                        .font(.headline)
                        .foregroundStyle(IMColor.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: onClear) {
                        Text("清空")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(IMColor.peerName)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(Capsule().fill(IMColor.brand.opacity(0.08)))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)
                let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(terms, id: \.self) { term in
                        if term != terms.first {
                            Divider().padding(.leading, 56)
                        }
                        HStack(spacing: 0) {
                            Button { onSelect(term) } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(IMColor.brand)
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(IMColor.brand.opacity(0.08)))
                                        .accessibilityHidden(true)
                                    Text(term)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 14)
                                .frame(minHeight: 54)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { onRemove(term) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(IMColor.page))
                                    .frame(width: 48, height: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除 \(term)")
                        }
                    }
                }
                .background(shape.fill(IMColor.card))
                .overlay(shape.strokeBorder(IMColor.line, lineWidth: 1))
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_END
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TenantGlobalSearchResultsView: View {
    let data: TenantGlobalSearchPageData?
    let projection: TenantGlobalSearchProjection
    let requestedKey: TenantGlobalSearchKey
    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
    let isLoading: Bool
    let isPaging: Bool
    let failure: TenantSearchFailure?
    let onRetry: () -> Void
    let onSelectCategory: (TenantGlobalSearchCategory?) -> Void
    let onRemoveFilter: (RemoteTenantSearchParsedFilter) -> Void
    let onNextPage: (TenantGlobalSearchCursor, Bool) -> Void
    let onSelect: (TenantGlobalSearchRow) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let failure { notice(failure.message, retry: failure.canRetry ? onRetry : nil) }
            // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
            if isLoading { loading("正在搜索") }
            if let data {
                responseContent(data)
            }
        }
        .accessibilityIdentifier("tenant_global_search_results")
    }

    @ViewBuilder private func responseContent(_ data: TenantGlobalSearchPageData) -> some View {
        let active = data.key == requestedKey && !isLoading && failure == nil
        let response = data.response
        if active, !response.parsedFilters.isEmpty {
            TenantSearchParsedFilterChips(filters: response.parsedFilters, onRemove: onRemoveFilter)
        }

        ForEach(data.key.types) { category in
            let rows = projection.rows[category] ?? []
            let bucket = response.resultsByType[category.rawValue]
            if let coverage = globalSearchCoverage(response, category: category) {
                let error = bucket?.error ?? response.errorsByType[category.rawValue]
                notice(coverage, retry: active && (error?.retryable ?? (bucket?.status == "unavailable" || bucket == nil)) ? onRetry : nil)
            }

            if !rows.isEmpty {
                sectionTitle(category)
                ForEach(data.key.category == nil ? Array(rows.prefix(5)) : rows) { row in
                    Button {
                        onSelect(row)
                    } label: {
                        TenantSearchResultRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tenant_search_result_\(row.item.type)_\(row.item.resultID)")
                    .disabled(!active)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.94)))
                }
            }
            if active, data.key.category == nil, !rows.isEmpty || bucket?.hasMore == true {
                Button("查看更多\(category.title)") { onSelectCategory(category) }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(IMColor.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .accessibilityIdentifier("tenant_search_more_\(category.rawValue)")
            }
        }

        if active, let pageFailure = data.pageFailure {
            notice(pageFailure.message, retry: pageFailure.canRetry ? onRetry : nil)
        } else if active, let cursor = data.nextCursor {
            if isPaging {
                loading("正在加载更多")
            } else {
                Button("加载更多") { onNextPage(cursor, false) }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(IMColor.brand)
                    .padding(12)
                    .id(cursor)
                    .onAppear { onNextPage(cursor, false) }
            }
        }

        if active, !isPaging, data.nextCursor == nil, data.pageFailure == nil,
           !response.degraded, data.key.types.allSatisfy({
               let bucket = response.resultsByType[$0.rawValue]
               return projection.rows[$0]?.isEmpty != false && bucket != nil && bucket?.hasMore == false
                   && globalSearchCoverage(response, category: $0) == nil
           }) {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: data.key.category == nil ? "没有搜索结果" : "当前分类无结果",
                subtitle: "换个关键词试试。"
            )
        } else if active, response.degraded,
                  data.key.types.allSatisfy({ globalSearchCoverage(response, category: $0) == nil }) {
            notice("部分分类搜索暂不可用", retry: onRetry)
        }
    }

    private func sectionTitle(_ category: TenantGlobalSearchCategory) -> some View {
        Label(category.title, systemImage: category.icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(IMColor.ink)
            .padding(.top, 4)
    }

    private func notice(_ message: String, retry: (() -> Void)? = nil) -> some View {
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_BEGIN
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 12) {
            Text(message).font(.subheadline).foregroundStyle(IMColor.muted)
            Spacer()
            if let retry {
                Button(action: retry) {
                    Text("重试")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IMColor.brand))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tenant_global_search_retry")
            }
        }
        .padding(12)
        .background(shape.fill(IMColor.card))
        .overlay(shape.strokeBorder(IMColor.line, lineWidth: 1))
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_END
    }

    private func loading(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(IMColor.brand)
            Text(message).font(.subheadline).foregroundStyle(IMColor.muted)
            Spacer()
        }
        .padding(12)
    }
}

struct TenantGlobalSearchTypeTabs: View {
    let category: TenantGlobalSearchCategory?
    let onSelect: (TenantGlobalSearchCategory?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", for: nil)
                ForEach(TenantGlobalSearchCategory.allCases) { chip($0.title, for: $0) }
            }
        }
    }

    private func chip(_ title: String, for type: TenantGlobalSearchCategory?) -> some View {
        Button {
            onSelect(type)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(category == type ? .white : IMColor.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(category == type ? IMColor.brand : .white.opacity(0.96)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(category == type ? .isSelected : [])
    }
}

private struct TenantSearchParsedFilterChips: View {
    let filters: [RemoteTenantSearchParsedFilter]
    let onRemove: (RemoteTenantSearchParsedFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    Button {
                        onRemove(filter)
                    } label: {
                        HStack(spacing: 5) {
                            Text(filter.displayTitle)
                                .font(.system(size: 11, weight: .black))
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .black))
                        }
                        .foregroundStyle(IMColor.brand)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(IMColor.brand.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TenantSearchResultRow: View {
    let row: TenantGlobalSearchRow
    private var item: RemoteTenantSearchResult { row.item }
    private var displayModel: TenantSearchResultDisplayModel { row.display }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(iconColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TenantSearchHighlightedText(
                        text: row.contactName ?? displayModel.primaryText,
                        ranges: highlightRanges(for: displayModel.primaryField, text: row.contactName ?? displayModel.primaryText),
                        field: displayModel.primaryField,
                        font: .system(size: 14, weight: .black),
                        color: IMColor.ink
                    )
                    if let exactUID = row.contactUID { // WDT_IOS1_REFACTOR_SEARCH_AND_CALL_CONTACT_OBSERVATION_20261110
                        CertificationPillView(
                            exactUID: exactUID,
                            compact: true
                        )
                    }
                }
                if let detailText = displayModel.secondaryText {
                    TenantSearchHighlightedText(
                        text: detailText,
                        ranges: highlightRanges(for: displayModel.secondaryField, text: detailText),
                        field: displayModel.secondaryField,
                        font: .system(size: 12, weight: .semibold),
                        color: IMColor.muted
                    )
                    .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(IMColor.muted.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func highlightRanges(for field: String, text: String) -> [RemoteTenantSearchHighlightRange] {
        let raw: String?
        switch field {
        case "title": raw = item.title
        case "snippet": raw = item.snippet
        case "subtitle": raw = item.subtitle
        default: raw = nil
        }
        return raw == text ? item.highlightRanges : []
    }

    private var iconName: String {
        switch item.type {
        case "contact", "contacts": return "person.crop.circle"
        case "group", "groups": return "person.3.fill"
        case "conversation", "conversations": return "bubble.left.and.bubble.right.fill"
        case "message", "messages": return "text.bubble.fill"
        case "file", "files": return "doc.fill"
        default: return "magnifyingglass"
        }
    }

    private var iconColor: Color {
        switch item.type {
        case "contact", "contacts": return IMColor.success
        case "group", "groups": return IMColor.brand
        case "conversation", "conversations": return IMColor.cyan
        case "message", "messages": return IMColor.warning
        case "file", "files": return IMColor.violet
        default: return IMColor.brand
        }
    }


}

private struct TenantSearchHighlightedText: View {
    let text: String
    let ranges: [RemoteTenantSearchHighlightRange]
    let field: String
    let font: Font
    let color: Color

    var body: some View {
        highlightedText.font(font).lineLimit(1)
    }

    private var highlightedText: Text {
        let ordered = ranges.filter { $0.field == field }.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return Text(text).foregroundColor(color) }
        let scalars = Array(text.unicodeScalars)
        let valid = ordered.allSatisfy {
            $0.start >= 0 && $0.length > 0 && $0.start <= scalars.count && $0.length <= scalars.count - $0.start
        }
        guard valid else { return Text(text).foregroundColor(color) }
        var output = AttributedString()
        var cursor = 0
        for range in ordered {
            let start = max(cursor, range.start)
            let end = range.start + range.length
            guard end > start else { continue }
            if start > cursor {
                var gap = AttributedString(String(String.UnicodeScalarView(scalars[cursor..<start])))
                gap.foregroundColor = color
                output += gap
            }
            var match = AttributedString(String(String.UnicodeScalarView(scalars[start..<end])))
            match.foregroundColor = IMColor.brand
            output += match
            cursor = end
        }
        var suffix = AttributedString(String(String.UnicodeScalarView(scalars[cursor...])))
        suffix.foregroundColor = color
        output += suffix
        return Text(output)
    }
}
// WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END

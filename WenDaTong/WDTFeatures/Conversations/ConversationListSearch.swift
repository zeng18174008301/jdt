import Combine
import IM4DesignSystem
import SwiftUI
import UIKit

// WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
extension ConversationListView {
    var trimmedSearchQuery: String {
        guard filter == "@我" else { return "" }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TenantGlobalSearchPresentation: Identifiable {
    let id = UUID()
    let owner: ChatBubbleSessionIdentity
    let deployment: String?
    let returnToken: Int
}

private struct TenantGlobalSearchFileRoute: Identifiable {
    let file: FileItem
    let resultID: String

    var id: String { resultID }
}

@MainActor
struct TenantGlobalSearchPage: View {
    let presentation: TenantGlobalSearchPresentation

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatFeatureRouting) private var chatRouting
    @Environment(\.contactsFeatureRouting) private var contactsRouting

    @State private var query = ""
    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
    @State private var submittedQuery: String?
    @State private var category: TenantGlobalSearchCategory?
    @State private var isFocused = false
    @State private var isVisible = false
    @State private var didAppear = false
    @State private var isRetired = false
    @State private var recent: [String] = []

    @State private var page: TenantGlobalSearchPageData?
    @State private var projection = TenantGlobalSearchProjection()
    @State private var failure: TenantSearchFailure?
    @State private var isLoading = false
    @State private var isPaging = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestGeneration: UInt64 = 0
    @State private var issuedKey: TenantGlobalSearchKey?
    @State private var attemptedCursor: TenantGlobalSearchCursor?

    @State private var cache: [TenantGlobalSearchKey: TenantGlobalSearchPageData] = [:]
    @State private var cacheOrder: [TenantGlobalSearchKey] = []
    @State private var invalidations: [SearchInvalidationEvent] = []
    @State private var contactDirectory: ContactStore.DirectoryPresentationSnapshot?
    @State private var blacklistIDs: Set<String>?
    @State private var groupIDs: Set<String>?
    @State private var removedGroupIDs: Set<String> = []
    @State private var removedContactIDs: Set<String> = []
    @State private var locallyRevokedResultIDs: Set<String> = []
    @State private var showsProcessingNotices: Bool?

    @State private var conversationRoute: ConversationListRoute?
    @State private var profileRoute: IMUser?
    @State private var profileConversationRoute: ConversationListRoute?
    @State private var fileRoute: TenantGlobalSearchFileRoute?
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionID = UUID()
    @State private var selectingResultID: String?

    private var key: TenantGlobalSearchKey {
        TenantGlobalSearchKey(query: query.trimmingCharacters(in: .whitespacesAndNewlines), category: category)
    }

    private var ownsCurrentScope: Bool {
        !isRetired && state.apiContext.hasIMSession && presentation.owner == state.chatBubbleSessionIdentity
            && presentation.deployment == state.apiContext.tenantAPIBaseURL
    }

    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
    var body: some View {
        NavigationStackCompat {
            screen
                .navigationDestinationCompat(item: $conversationRoute) { route in
                    if ownsCurrentScope {
                        requiredChatRouting(chatRouting).makeChat(route.conversationID, initialSearchJumpTarget: route.initialSearchJumpTarget)
                    }
                }
                .navigationDestinationCompat(item: $profileRoute) { user in
                    if ownsCurrentScope {
                        requiredContactsRouting(contactsRouting).makeUserProfile(user: user, onOpenConversation: { conversationID in
                            guard ownsCurrentScope, profileRoute == user else { return }
                            profileConversationRoute = ConversationListRoute(conversationID: conversationID, initialSearchJumpTarget: nil)
                        })
                        .navigationDestinationCompat(item: $profileConversationRoute) { route in
                            if ownsCurrentScope {
                                requiredChatRouting(chatRouting).makeChat(route.conversationID)
                            }
                        }
                    }
                }
                .sheet(item: $fileRoute) { route in
                    if ownsCurrentScope {
                        FilePreviewView(file: route.file)
                            .environmentObject(state)
                    }
                }
        }
        .onReceive(state.chatBubbleSessionIdentitySource.updates) { _ in
            if !ownsCurrentScope { retirePage() }
        }
        .onChangeCompat(of: ownsCurrentScope) { _, ownsScope in
            if !ownsScope { retirePage() }
        }
        .onReceive(state.conversationListPresentationStore.$snapshot.map(\.returnToken).removeDuplicates()) { token in
            if token != presentation.returnToken && (conversationRoute != nil || profileConversationRoute != nil) {
                retirePage()
            }
        }
        .onReceive(state.searchInvalidationStore.updates, perform: receiveInvalidation)
        .onReceive(state.contactStore.directoryPresentationUpdates, perform: receiveContactDirectory)
        .onReceive(state.contactStore.blacklistUpdates) { blacklist in
            let ids = Set(blacklist.map { normalized($0.id) })
            guard blacklistIDs != ids else { return }
            blacklistIDs = ids
            refreshVisibility()
        }
        .onReceive(state.contactStore.groupDirectoryUpdates) { groups in
            let ids = Set(groups.map { normalized($0.id) })
            guard groupIDs != ids else { return }
            if let groupIDs { removedGroupIDs.formUnion(groupIDs.subtracting(ids)) }
            removedGroupIDs.subtract(ids)
            groupIDs = ids
            refreshVisibility()
        }
        .onReceive(state.tenantInteractionStore.updates(\.showsProcessingNotices)) { value in
            guard showsProcessingNotices != value else { return }
            showsProcessingNotices = value
            refreshVisibility()
        }
        .onReceive(state.conversationStore.memoryCommits) { commit in
            guard ownsCurrentScope, commit.bindingID == state.conversationStore.messageMemoryStore.bindingID else { return }
            let affectedIDs = commit.changedConversationRowIDs.union(commit.messageChanges.keys)
            if commit.conversationOrderChanged {
                refreshVisibility()
            } else if !affectedIDs.isEmpty {
                cacheOrder.removeAll { key in
                    guard let cached = cache[key], !affectedIDs.isDisjoint(with: cached.conversationIDs) else { return false }
                    cache[key] = nil
                    return true
                }
                if !affectedIDs.isDisjoint(with: projection.conversationIDs) {
                    refreshVisibility(invalidateCache: false)
                }
            }
        }
    }

    private var screen: some View {
        VStack(spacing: 0) {
            // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_BEGIN
            searchField
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if ownsCurrentScope && !key.query.isEmpty {
                TenantGlobalSearchTypeTabs(category: category, onSelect: selectCategory)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_END
            }

            ScrollView {
                if ownsCurrentScope {
                    if key.query.isEmpty {
                        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
                        TenantGlobalSearchRecentView(terms: recent, onSelect: changeQuery, onRemove: { term in
                            guard ownsCurrentScope else { return }
                            state.removeTenantSearch(term, conversationID: nil, owner: presentation.owner)
                            reloadHistory()
                        }, onClear: {
                            guard ownsCurrentScope else { return }
                            state.clearTenantSearchHistory(conversationID: nil, owner: presentation.owner)
                            reloadHistory()
                        })
                        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                    } else if submittedQuery == key.query {
                        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
                        TenantGlobalSearchResultsView(
                            data: page, projection: projection, requestedKey: key,
                            // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113
                            isLoading: isLoading, isPaging: isPaging,
                            failure: failure, onRetry: retry, onSelectCategory: selectCategory,
                            onRemoveFilter: removeFilter, onNextPage: loadMore, onSelect: selectResult
                        )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
                    } else {
                        Text("点「搜索」查找关键词")
                            .font(.subheadline)
                            .foregroundStyle(IMColor.muted)
                            .padding(18)
                    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
                    }
                }
            }
            .id(category)
            .accessibilityIdentifier("tenant_global_search_scroll")
        }
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_BEGIN
        .background(alignment: .top) {
            IMColor.page
                .overlay(alignment: .top) {
                    LinearGradient(colors: [IMColor.brand.opacity(0.07), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 230)
                }
                .ignoresSafeArea()
        }
        // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_END
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: retirePage)
            }
        }
        .onAppear {
            guard ownsCurrentScope else { retirePage(); return }
            isVisible = true
            recent = state.recentTenantSearches(conversationID: nil, owner: presentation.owner)
            if !didAppear {
                didAppear = true
                isFocused = true
            // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
            }
        }
        .onDisappear {
            isVisible = false
            isFocused = false
            retireRequest()
            retireSelection()
        }
    }

    // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_BEGIN
    private var searchField: some View {
        let canSearch = !key.query.isEmpty
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFocused ? IMColor.brand : IMColor.muted)
                .accessibilityHidden(true)
            CommittedSearchInput(
                // WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_BEGIN
                text: Binding(get: { query }, set: { value in changeQuery(value) }),
                // WDT_IOS1_BINDING_SETTER_COMPILER_COMPAT_20261113_END
                placeholder: "搜索联系人、群聊、消息或文件",
                focus: $isFocused,
                placeholderColor: UIColor(IMColor.ink.opacity(0.62)),
                onSubmit: submit
            )
            .accessibilityIdentifier("tenant_global_search_field")
            if !query.isEmpty {
                Button { changeQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Button(action: submit) {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canSearch ? .white : IMColor.peerName)
                    .frame(minWidth: 58, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canSearch ? IMColor.brand : IMColor.page))
            }
            .buttonStyle(.plain)
            .disabled(!canSearch)
            .accessibilityIdentifier("tenant_global_search_submit")
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 54)
        .background(shape.fill(IMColor.card))
        .overlay(shape.strokeBorder(isFocused ? IMColor.brand.opacity(0.34) : IMColor.line, lineWidth: 1))
        .shadow(color: IMColor.ink.opacity(0.045), radius: 7, x: 0, y: 2)
    }

    // WDT_IOS1_GLOBAL_SEARCH_VISUALS_20261113_END
    private func reloadHistory() {
        recent = state.recentTenantSearches(conversationID: nil, owner: presentation.owner)
    }

    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
    private func changeQuery(_ value: String) {
        let previous = key
        query = value
        guard previous != key else { return }
        if key.query.isEmpty { category = nil }
        submittedQuery = nil
        retireRequest()
        retireSelection()
        page = nil
        projection = TenantGlobalSearchProjection()
        failure = nil
    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
    }

    private func submit() {
        guard ownsCurrentScope, isVisible, !key.query.isEmpty else { return }
        isFocused = false
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
        submittedQuery = key.query
        if validate(key) == nil {
            state.recordTenantSearch(key.query, conversationID: nil, owner: presentation.owner)
            reloadHistory()
        }
        searchSubmittedQuery(force: failure != nil)
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
    }

    private func selectCategory(_ selected: TenantGlobalSearchCategory?) {
        guard selected != category else { return }
        category = selected
        page = nil
        projection = TenantGlobalSearchProjection()
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
        searchSubmittedQuery()
    }

    private func validate(_ key: TenantGlobalSearchKey) -> TenantSearchFailure? {
        if key.query.unicodeScalars.count > 64 || key.query.utf8.count > 256 { return .invalidQuery }
        if key.category == .messages && key.query.unicodeScalars.count < 2 { return .shortMessageQuery }
        return nil
    }

    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
    private func searchSubmittedQuery(force: Bool = false) {
        let requested = key
        guard ownsCurrentScope, isVisible, submittedQuery == requested.query else { return }
    // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
        if !force {
            if isLoading && issuedKey == requested { return }
            if page?.key == requested && failure == nil && !isLoading { return }
        }
        retireRequest()
        retireSelection()
        failure = nil
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
        if let validation = validate(requested) {
            page = nil
            projection = TenantGlobalSearchProjection()
            failure = validation
            return
        }
        if !force, let cached = cache[requested] {
            install(cached)
            return
        }
        if force {
            cache[requested] = nil
            cacheOrder.removeAll { $0 == requested }
        }

        let generation = requestGeneration
        isLoading = true
        requestTask = Task { @MainActor in
            // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
            guard ownsRequest(requested, generation: generation) else { return }
            issuedKey = requested
            let response = await state.tenantSearch(
                query: requested.query, scope: "global", types: requested.types.map(\.rawValue),
                limit: requested.category == nil ? 10 : 20,
                cursorV2: requested.category == .messages ? "" : nil
            )
            guard ownsRequest(requested, generation: generation) else { return }
            requestTask = nil
            issuedKey = nil
            isLoading = false
            switch response {
            case .response(let response):
                var data = TenantGlobalSearchPageData(key: requested, response: response)
                if let category = requested.category,
                   response.resultsByType[category.rawValue]?.hasMore == true, data.nextCursor == nil {
                    data.pageFailure = .cursorExpired
                }
                install(data)
                if projection.rows.values.contains(where: { !$0.isEmpty }) {
                    postAnalytics("success", key: requested, context: TenantGlobalSearchAnalyticsContext(response))
                } else if !response.degraded && requested.types.allSatisfy({
                    let bucket = response.resultsByType[$0.rawValue]
                    return bucket != nil && bucket?.hasMore == false
                        && globalSearchCoverage(response, category: $0) == nil
                }) {
                    postAnalytics("zero_result", key: requested, context: TenantGlobalSearchAnalyticsContext(response))
                }
            case .failure(let error):
                if error == .access {
                    page = nil
                    projection = TenantGlobalSearchProjection()
                    clearCache()
                }
                failure = error
            case .retired:
                break
            }
        }
    }

    private func ownsRequest(_ requested: TenantGlobalSearchKey, generation: UInt64) -> Bool {
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_BEGIN
        !Task.isCancelled && isVisible && ownsCurrentScope && submittedQuery == requested.query
            && key == requested && requestGeneration == generation
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113_END
    }

    private func retireRequest() {
        if let issuedKey {
            let context = isPaging ? page.map { TenantGlobalSearchAnalyticsContext($0.response) } : nil
            postAnalytics("cancel", key: issuedKey, context: context)
        }
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
        issuedKey = nil
        attemptedCursor = nil
        isLoading = false
        isPaging = false
    }

    private func retireSelection() {
        selectionID = UUID()
        selectionTask?.cancel()
        selectionTask = nil
        selectingResultID = nil
    }

    private func retirePage() {
        guard !isRetired else { return }
        retireRequest()
        retireSelection()
        isRetired = true
        query = ""
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
        submittedQuery = nil
        page = nil
        projection = TenantGlobalSearchProjection()
        locallyRevokedResultIDs = []
        failure = nil
        recent = []
        fileRoute = nil
        profileRoute = nil
        profileConversationRoute = nil
        conversationRoute = nil
        clearCache()
        dismiss()
    }

    private func retry() {
        if let page, page.key == key, let pageFailure = page.pageFailure,
           pageFailure != .cursorExpired, let cursor = page.nextCursor {
            loadMore(cursor, retry: true)
        } else {
            // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
            searchSubmittedQuery(force: true)
        }
    }

    private func loadMore(_ cursor: TenantGlobalSearchCursor, retry: Bool = false) {
        let requested = key
        // WDT_IOS1_GLOBAL_SEARCH_SUBMISSION_20261113
        guard isVisible, ownsCurrentScope, submittedQuery == requested.query, !isLoading, !isPaging, failure == nil,
              var current = page, current.key == requested, current.nextCursor == cursor,
              let type = requested.category?.rawValue,
              retry || (attemptedCursor != cursor && current.pageFailure == nil) else { return }
        if let legacy = cursor.legacy, let offset = Int(legacy), offset > 1000 {
            current.pageFailure = .legacyPageLimit
            page = current
            remember(current)
            return
        }
        attemptedCursor = cursor
        isPaging = true
        issuedKey = requested
        current.pageFailure = nil
        page = current
        let generation = requestGeneration
        requestTask = Task { @MainActor in
            guard ownsRequest(requested, generation: generation) else { return }
            let outcome = await state.tenantSearch(
                query: requested.query, scope: "global", types: [type], limit: 20,
                cursor: cursor.legacy, cursorV2: cursor.v2,
                typeCursors: cursor.legacy.map { [type: $0] } ?? [:]
            )
            guard ownsRequest(requested, generation: generation),
                  var latest = page, latest.key == requested, latest.nextCursor == cursor else { return }
            requestTask = nil
            issuedKey = nil
            isPaging = false
            switch outcome {
            case .response(let next) where next.resultsByType[type].map({ $0.status != "unavailable" }) == true:
                latest.append(next, type: type, cursor: cursor)
                if let bucket = latest.response.resultsByType[type], bucket.hasMore, latest.nextCursor == nil {
                    latest.pageFailure = .cursorExpired
                }
                install(latest)
                postAnalytics("success", key: requested, context: TenantGlobalSearchAnalyticsContext(next))
            case .response:
                latest.pageFailure = .unavailable
                page = latest
                remember(latest)
            case .failure(let error):
                if error == .access {
                    page = nil
                    projection = TenantGlobalSearchProjection()
                    clearCache()
                    failure = error
                } else {
                    latest.pageFailure = error
                    page = latest
                    remember(latest)
                }
            case .retired:
                attemptedCursor = nil
            }
        }
    }

    private func install(_ data: TenantGlobalSearchPageData) {
        var data = data
        let rows = makeProjection(data)
        data.conversationIDs = rows.conversationIDs
        page = data
        projection = rows
        remember(data)
    }

    private func remember(_ data: TenantGlobalSearchPageData) {
        let response = data.response
        guard !response.degraded, response.errorsByType.isEmpty,
              data.key.types.allSatisfy({
                  let bucket = response.resultsByType[$0.rawValue]
                  return bucket != nil && bucket?.status != "unavailable" && bucket?.error == nil
                      && bucket?.authoritative != false
              }) else {
            cache[data.key] = nil
            cacheOrder.removeAll { $0 == data.key }
            return
        }
        cache[data.key] = data
        cacheOrder.removeAll { $0 == data.key }
        cacheOrder.append(data.key)
        if cacheOrder.count > 8 {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func receiveInvalidation(_ event: SearchInvalidationEvent) {
        if event.isTenantScopeReset {
            retirePage()
        } else if ownsCurrentScope {
            invalidations.append(event)
            refreshVisibility()
        }
    }

    private func receiveContactDirectory(_ snapshot: ContactStore.DirectoryPresentationSnapshot) {
        guard contactDirectory != snapshot else { return }
        if let contactDirectory {
            let previous = Set(contactDirectory.contacts.flatMap { [$0.id, $0.userID] }.map(normalized))
            let current = Set(snapshot.contacts.flatMap { [$0.id, $0.userID] }.map(normalized))
            removedContactIDs.formUnion(previous.subtracting(current))
            removedContactIDs.subtract(current)
        }
        contactDirectory = snapshot
        refreshVisibility()
    }

    private func refreshVisibility(invalidateCache: Bool = true) {
        guard ownsCurrentScope else { return }
        if invalidateCache { clearCache() }
        guard var page else { return }
        let rows = makeProjection(page)
        page.conversationIDs = rows.conversationIDs
        self.page = page
        projection = rows
        if let selectingResultID, rows.row(id: selectingResultID, for: page.key) == nil {
            retireSelection()
        }
        if let fileRoute, rows.row(id: fileRoute.resultID, for: page.key) == nil {
            self.fileRoute = nil
        }
        if let profileRoute, isContactUnavailable([profileRoute.id, profileRoute.userID], user: profileRoute) {
            self.profileRoute = nil
            profileConversationRoute = nil
        }
    }

    private func isContactUnavailable(_ identifiers: [String], user: IMUser?) -> Bool {
        let identifiers = Set((identifiers + (user.map { [$0.id, $0.userID, $0.username] } ?? []))
            .map(normalized).filter { !$0.isEmpty })
        let blocked = blacklistIDs ?? Set(state.blacklist.map { normalized($0.id) })
        return user?.isCancelledUser == true || !removedContactIDs.isDisjoint(with: identifiers)
            || !blocked.isDisjoint(with: identifiers)
    }

    private func removeFilter(_ filter: RemoteTenantSearchParsedFilter) {
        let candidates = [filter.raw, filter.operatorName.map { "\($0):\(filter.value)" },
                          filter.key.isEmpty ? nil : "\(filter.key):\(filter.value)"]
        var updated = query
        for candidate in candidates {
            let token = normalized(candidate)
            if !token.isEmpty { updated = updated.replacingOccurrences(of: token, with: "", options: [.caseInsensitive]) }
        }
        updated = updated.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if updated == query {
            state.setToast("请直接编辑搜索关键词调整筛选")
        } else {
            changeQuery(updated)
        }
    }

    private func postAnalytics(
        _ event: String, key: TenantGlobalSearchKey, context: TenantGlobalSearchAnalyticsContext?, item: RemoteTenantSearchResult? = nil
    ) {
        guard ownsCurrentScope else { return }
        state.postTenantSearchEvent(TenantSearchAnalyticsEvent(
            searchID: context?.searchID, requestID: context?.requestID, eventType: event, scope: "global",
            types: key.types.map(\.rawValue), resultType: item?.type, resultID: item?.resultID,
            resultRank: item?.rank, queryLength: key.query.unicodeScalars.count, elapsedMS: context?.elapsedMS,
            filters: context?.filters ?? [:]
        ))
    }

    private func makeProjection(_ data: TenantGlobalSearchPageData) -> TenantGlobalSearchProjection {
        let buckets = data.response.resultsByType
        let all = data.key.types.flatMap { buckets[$0.rawValue]?.items ?? [] }
        let channels = Set(all.compactMap { item -> String? in
            let channel = normalized(item.jumpTarget?.channelID)
            return channel.isEmpty ? nil : channel
        })
        let store = state.conversationStore
        let lookup = channels.isEmpty ? nil : state.makeConversationUserLookup()
        var conversations: [String: ConversationMessageSnapshot] = [:]
        if let lookup {
            for metadata in store.conversations {
                let row = ConversationMessageSnapshot(conversation: metadata, messages: [])
                let remoteID = state.remoteChannelID(for: row, lookup: lookup)
                for channel in [row.id, remoteID] where channels.contains(channel) && conversations[channel] == nil {
                    conversations[channel] = row
                }
            }
        }

        let directory = contactDirectory ?? state.contactStore.directoryPresentationSnapshot
        let contacts = data.key.types.contains(.contacts)
            ? DirectConversationCallPeerResolver.ContactLookup(contacts: directory.contacts) : nil

        // Only index windows containing message/file hits in this response.
        let targetConversations = Set(all.compactMap { item -> String? in
            guard let target = item.jumpTarget, target.messageID != nil || (target.channelSeq ?? 0) > 0 else { return nil }
            return conversations[normalized(target.channelID)]?.id
        })
        var revokedMessages: [String: Set<String>] = [:]
        var revokedSequences: [String: Set<Int64>] = [:]
        var hiddenNoticeMessages: [String: Set<String>] = [:]
        var hiddenNoticeSequences: [String: Set<Int64>] = [:]
        let showNotices = showsProcessingNotices ?? state.shouldShowMessageProcessingNotices
        for id in targetConversations {
            let messages = store.conversationMessageSnapshot(id: id)?.messages ?? []
            for message in messages {
                // The server hit carries searchable text, not the processing notice shown in chat.
                if message.isDeletedLocally || message.status == .recalled {
                    revokedMessages[id, default: []].insert(message.id)
                    if message.channelSeq > 0 { revokedSequences[id, default: []].insert(message.channelSeq) }
                } else if !showNotices && message.kind == .system {
                    hiddenNoticeMessages[id, default: []].insert(message.id)
                    if message.channelSeq > 0 { hiddenNoticeSequences[id, default: []].insert(message.channelSeq) }
                }
            }
        }

        var result = TenantGlobalSearchProjection()
        result.conversationIDs = Set(conversations.values.map(\.id))
        var revokedResultIDs = locallyRevokedResultIDs
        for type in data.key.types {
            var seen: Set<String> = []
            result.rows[type] = (buckets[type.rawValue]?.items ?? []).compactMap { item in
                guard seen.insert(item.id).inserted, !item.isBlockedFromChatSearchDisplay, !revokedResultIDs.contains(item.id),
                      !invalidations.contains(where: { item.matchesSearchInvalidation($0) }) else { return nil }
                let target = item.jumpTarget
                let channel = normalized(target?.channelID)
                let conversation = conversations[channel]
                let sequence = target?.channelSeq ?? 0
                if normalized(target?.channelType).lowercased() == "group", removedGroupIDs.contains(channel) { return nil }
                if let conversation {
                    if sequence > 0, let boundary = store.historyBoundary(for: conversation),
                       boundary.isRestrictive, sequence < boundary.fromSeq { return nil }
                    let messageID = normalized(target?.messageID)
                    if revokedMessages[conversation.id]?.contains(messageID) == true
                        || revokedSequences[conversation.id]?.contains(sequence) == true {
                        revokedResultIDs.insert(item.id)
                        return nil
                    }
                    if hiddenNoticeMessages[conversation.id]?.contains(messageID) == true
                        || hiddenNoticeSequences[conversation.id]?.contains(sequence) == true { return nil }
                }
                let uid = TenantGlobalSearchRow.contactExactUID(for: item)
                let userID = normalized(target?.userID)
                let contact = contacts?.firstContact(matchingAny: [uid ?? "", userID])
                if type == .contacts, isContactUnavailable([uid ?? "", userID], user: contact) { return nil }
                return TenantGlobalSearchRow(
                    item: item, display: item.displayModel,
                    contactName: contact.map { state.remarkPreferredDisplayName(for: $0, contactLookup: contacts, directory: directory) },
                    contactUID: uid, conversationID: conversation?.id
                )
            }
        }
        if locallyRevokedResultIDs != revokedResultIDs { locallyRevokedResultIDs = revokedResultIDs }
        return result
    }

    private func selectResult(_ row: TenantGlobalSearchRow) {
        let requested = key
        guard let current = currentSelection(row.id, key: requested) else { return }
        guard let target = current.item.jumpTarget else {
            state.setToast("搜索结果暂不可跳转")
            return
        }
        let analytics = page?.analytics(for: row.id)
        retireSelection()
        isFocused = false
        let selection = selectionID
        selectingResultID = row.id
        let kind = normalized(target.kind).lowercased()
        switch kind {
        case "file", "message_file":
            let rawID = current.item.resultID
            let fallback = rawID.hasPrefix("file:") ? String(rawID.dropFirst(5)) : rawID
            let fileID = normalized(target.fileID ?? fallback)
            guard !fileID.isEmpty else { state.setToast("未找到文件编号"); return }
            selectionTask = Task { @MainActor in
                let ownsSelection: @MainActor () -> Bool = {
                    !Task.isCancelled && selectionID == selection
                        && currentSelection(row.id, key: requested)?.item.jumpTarget == target
                }
                guard let file = await state.fileItemForSearchResult(
                    fileID: fileID, fallbackName: current.item.title, ownsSelection: ownsSelection
                ), ownsSelection() else { return }
                recordSelection(current.item, key: requested, analytics: analytics)
                fileRoute = TenantGlobalSearchFileRoute(file: file, resultID: row.id)
            }
        case "user_profile":
            guard let uid = current.contactUID else { state.setToast("联系人资料暂不可用"); return }
            openProfile(uid: uid, row: current, key: requested, selection: selection, analytics: analytics)
        default:
            guard let conversationID = resolveConversation(for: current, target: target) else {
                state.setToast("未找到来源会话")
                return
            }
            // Creating a known conversation can synchronously emit memory events.
            guard currentSelection(row.id, key: requested) != nil else { return }
            recordSelection(current.item, key: requested, analytics: analytics)
            conversationRoute = ConversationListRoute(
                conversationID: conversationID, initialSearchJumpTarget: conversationListMessageJumpTarget(target)
            )
        }
    }

    private func currentSelection(_ id: String, key requested: TenantGlobalSearchKey) -> TenantGlobalSearchRow? {
        guard isVisible, ownsCurrentScope, !isLoading, requested == key, page?.key == requested,
              failure == nil else { return nil }
        return projection.row(id: id, for: requested)
    }

    private func recordSelection(
        _ item: RemoteTenantSearchResult, key requested: TenantGlobalSearchKey, analytics: TenantGlobalSearchAnalyticsContext?
    ) {
        state.recordTenantSearch(requested.query, conversationID: nil, owner: presentation.owner)
        reloadHistory()
        postAnalytics("click", key: requested, context: analytics, item: item)
    }

    private func resolveConversation(for row: TenantGlobalSearchRow, target: RemoteTenantSearchJumpTarget) -> String? {
        if let id = row.conversationID, state.conversationStore.conversation(id: id) != nil { return id }
        let channel = normalized(target.channelID)
        switch normalized(target.channelType).lowercased() {
        case "group":
            guard !removedGroupIDs.contains(channel), let group = state.group(id: channel) else { return nil }
            state.ensureGroupConversationExists(group)
            state.applyGroupHistoryBoundary(group)
            return state.conversationID(for: target)
        case "direct":
            let participantIDs = state.currentUserIdentitySet()
            let peer = [target.peerIMUID, target.imUID].compactMap { $0 }.first { !participantIDs.contains($0) }
                ?? channel.split(separator: ":").map(String.init).first { !participantIDs.contains($0) }
            guard let peer, let user = state.contacts.first(where: { state.user($0, matchesIdentifier: peer) }),
                  !state.isBlockedProfile(user) else { return nil }
            return state.openOrCreateDirectConversationID(for: user, activateChatsTab: false)
        default:
            return nil
        }
    }

    private func openProfile(
        uid: String, row: TenantGlobalSearchRow, key requested: TenantGlobalSearchKey,
        selection: UUID, analytics: TenantGlobalSearchAnalyticsContext?
    ) {
        if let user = state.contacts.first(where: { normalized($0.id) == uid }),
           !isContactUnavailable([uid], user: user), state.canStartDirectConversation(with: user) {
            recordSelection(row.item, key: requested, analytics: analytics)
            profileRoute = user
            return
        }

        let context = state.apiContext
        let owner = state.contactRequestOwner(context: context)
        selectionTask = Task { @MainActor in
            do {
                let profile = try await state.withContactHTTPRequest(owner: owner, context: context) {
                    try await state.api.friendProfile(context: context, canonicalFriendUID: uid)
                }
                guard !Task.isCancelled, selectionID == selection, currentSelection(row.id, key: requested) != nil,
                      state.contactRequestContext(for: owner) != nil,
                      normalized(profile.imUID) == uid, !isContactUnavailable([uid, profile.userID], user: nil) else { return }
                let name = [profile.displayName, profile.rawNickname, profile.nickname, uid]
                    .first(where: { !normalized($0).isEmpty }) ?? uid
                let user = IMUser(
                    id: uid, userID: profile.userID, name: name, title: "",
                    department: state.normalizedDepartmentName(profile.departmentName, pathNames: profile.departmentPathNames),
                    departmentPathNames: profile.departmentPathNames, phone: profile.visiblePhone,
                    email: "", status: "", enterprise: "", avatarSeed: state.stableSeed(uid),
                    avatarURL: profile.avatar, avatarVersion: profile.avatarVersion, avatarUpdatedAt: profile.avatarUpdatedAt,
                    badges: []
                )
                guard !user.isCancelledUser else { return }
                recordSelection(row.item, key: requested, analytics: analytics)
                profileRoute = user
            } catch {
                guard !Task.isCancelled, selectionID == selection, currentSelection(row.id, key: requested) != nil,
                      state.contactRequestContext(for: owner) != nil,
                      !state.isContactRequestCancellation(error) else { return }
                state.handleRemoteError(error, fallback: "联系人资料暂不可用")
            }
        }
    }
}

private func normalized(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func conversationListMessageJumpTarget(_ target: RemoteTenantSearchJumpTarget) -> RemoteTenantSearchJumpTarget? {
    let kind = normalized(target.kind).lowercased()
    guard kind != "conversation", kind != "conversations" else { return nil }
    let messageID = normalized(target.messageID)
    guard !messageID.isEmpty || (target.channelSeq ?? 0) > 0 else { return nil }
    return target
}
// WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END

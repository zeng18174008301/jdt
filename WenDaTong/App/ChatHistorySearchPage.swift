// WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
import Foundation
import IM4Features
import SwiftUI

struct ChatHistorySearchRequest: Sendable {
    let keyword: String
    let types: [String]
    var legacyCursors: [String: String] = [:]
    var cursorV2: String?
    var sender: String?
    var startAt: String?
    var endAt: String?
    var fileType: String?
    var hasLink = false // WDT_IOS1_SEARCH_LINK_FILTER_20261113
    var messageContent: String? // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
// WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
}

enum ChatHistorySearchRange: String, CaseIterable, Identifiable {
    case all, messages, images, videos, files, links, attachments // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "全部"
        case .messages: return "聊天记录"
        case .images: return "图片"
        case .videos: return "视频"
        case .files: return "文件"
        case .links: return "链接" // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        case .attachments: return "附件消息" // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        }
    }

    var types: [String] {
        switch self {
        case .all: return ["messages", "files"]
        case .messages, .links, .attachments: return ["messages"] // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        case .images, .videos, .files: return ["files"]
        }
    }

    var fileType: String? {
        switch self {
        case .images: return "image"
        case .videos: return "video"
        default: return nil
        }
    }

    var isMessageScoped: Bool { types == ["messages"] } // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
}

struct ChatHistorySearchCriteria: Equatable {
    let keyword: String
    let range: ChatHistorySearchRange
    let sender: String?
    let day: Date?

    static func dayBounds(_ day: Date, calendar: Calendar = .current) -> (String, String)? {
        let start = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let formatter = ISO8601DateFormatter()
        let lastSecond = formatter.string(from: next.addingTimeInterval(-1))
        return (formatter.string(from: start), String(lastSecond.dropLast()) + ".999999999Z")
    }

    func request(legacy: [String: String] = [:], cursorV2: String? = nil) -> ChatHistorySearchRequest {
        let bounds = day.flatMap { Self.dayBounds($0) }
        let types = legacy.isEmpty ? range.types : range.types.filter { legacy[$0] != nil }
        return ChatHistorySearchRequest(keyword: keyword, types: types, legacyCursors: legacy,
            cursorV2: cursorV2, sender: range.isMessageScoped ? sender : nil,
            startAt: bounds?.0, endAt: bounds?.1, fileType: range.fileType,
            hasLink: range == .links, messageContent: range == .attachments ? "attachment" : nil) // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
    }
}

struct ChatHistorySearchPageContext {
    let actions: ChatHistorySearchActions
    let conversationID: String
    let conversationChannel: String
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
    var conversationChannelType: String? = nil
    let currentOwner: @MainActor () -> ChatBubbleSessionIdentity
}

struct ChatHistorySearchJump {
    let target: RemoteTenantSearchJumpTarget
    let owner: ChatBubbleSessionIdentity
    let authority: UInt64
    let hitID: String?
    let dateStatus: String?
}

@MainActor
final class ChatHistorySearchSession: ObservableObject {
    @Published var keyword = ""
    @Published var anchorDate = ""
    @Published var range = ChatHistorySearchRange.all
    @Published var sender: String?
    @Published var filterDay: Date?
    @Published private(set) var recent: [String] = []
    @Published private(set) var rows: [ChatHistorySearchResultPresentation] = []
    @Published private(set) var focusedID: String?
    @Published private(set) var busy = false
    @Published private(set) var paging = false
    @Published private(set) var failure: TenantSearchFailure?
    @Published private(set) var pageFailure: TenantSearchFailure?
    @Published private(set) var coverage: String?
    @Published private(set) var exactTotal: Int?
    @Published private(set) var hasMore = false
    @Published private(set) var pageRevision: UInt64 = 0
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
    @Published private(set) var dateAvailabilityRevision: UInt64 = 0
    @Published private(set) var supportsLinks = false // WDT_IOS1_SEARCH_LINK_FILTER_20261113
    @Published private(set) var supportsAttachmentMessages = false // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113

    private(set) var owner: ChatBubbleSessionIdentity?
    private var conversationID: String?
    private var active: ChatHistorySearchCriteria?
    private var results: [RemoteTenantSearchResult] = []
    private var presentations: [String: ChatHistorySearchResultPresentation] = [:]
    private var provenance: [String: RemoteTenantSearchResponse] = [:]
    private var legacy: [String: String] = [:]
    private var messageCursorV2: String?
    private var lastAttempt: Work?
    private var sent: Work?
    private var consumedPages: Set<PageKey> = []
    private var invalidations: [String: SearchInvalidationEvent] = [:]
    private var locallyHiddenMessageIDs: Set<String> = []
    private var locallyHiddenMessageSequences: Set<Int64> = []
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    private var dateAnchors: [String: RemoteTenantSearchJumpTarget] = [:]
    private var dateAnchorsRevision: UInt64?
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    private var totals: [String: Int] = [:]
    private var limitedTypes: Set<String> = []
    private var filteredMatches = false
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var jumpAuthority: UInt64 = 0
    private var isPresented = false

    private enum Work: Equatable {
        case first(ChatHistorySearchCriteria)
        case page(ChatHistorySearchCriteria, PageKey)
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
    }

    private struct PageKey: Hashable {
        let messages: String?
        let files: String?
        let v2: String?

        var legacy: [String: String] {
            guard v2 == nil else { return [:] }
            var cursors: [String: String] = [:]
            cursors["messages"] = messages
            cursors["files"] = files
            return cursors
        }
    }

    var criteria: ChatHistorySearchCriteria {
        ChatHistorySearchCriteria(keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            range: range, sender: range.isMessageScoped ? sender : nil, day: filterDay) // WDT_IOS1_SEARCH_LINK_FILTER_20261113
    }

    var hasCurrentResponse: Bool { active == criteria }
    var retainedQuery: String? { hasCurrentResponse ? nil : active?.keyword }
    var focusedPosition: Int? { focusedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } }

    func open(_ context: ChatHistorySearchPageContext, currentMessages: [ChatMessage] = []) {
        let current = context.currentOwner()
        if owner != current || conversationID != context.conversationID {
            reset()
            owner = current
            conversationID = context.conversationID
        }
        isPresented = true
        observeLocalMessageWindow(currentMessages, context: context)
        refreshHistory(context)
    }

    func close(_ context: ChatHistorySearchPageContext) {
        if owns(context), let sent, busy || paging {
            track("cancel", work: sent, response: nil, context: context)
        }
        isPresented = false
        retire()
    }

    func reset() {
        isPresented = false
        retire()
        jumpAuthority &+= 1
        owner = nil
        conversationID = nil
        keyword = ""
        anchorDate = ""
        range = .all
        sender = nil
        filterDay = nil
        recent = []
        supportsLinks = false // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        supportsAttachmentMessages = false // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
        invalidations.removeAll()
        locallyHiddenMessageIDs.removeAll()
        locallyHiddenMessageSequences.removeAll()
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        dateAnchors.removeAll()
        dateAnchorsRevision = nil
        dateAvailabilityRevision &+= 1
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        clearResults()
    }

    func update(immediate: Bool = false, remember: Bool = false, context: ChatHistorySearchPageContext) {
        guard isPresented, let owner, owns(context) else { return }
        let query = criteria
        if remember && !query.keyword.isEmpty {
            context.actions.recordSearch(query.keyword, context.conversationID, owner)
            refreshHistory(context)
        }
        guard !query.keyword.isEmpty else {
            retire()
            clearResults()
            return
        }
        if query.range.isMessageScoped && query.keyword.unicodeScalars.count < 2 { // WDT_IOS1_SEARCH_LINK_FILTER_20261113
            retire()
            failure = .shortMessageQuery
            return
        }
        let work = Work.first(query)
        if !immediate && active == query && failure == nil { return }
        start(work, immediate: immediate, context: context)
    }

    func jumpToDate(_ context: ChatHistorySearchPageContext, onJump: @escaping @MainActor (ChatHistorySearchJump) -> Void) {
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        guard isPresented, owns(context), let owner else { return }
        guard dateAnchorsRevision == dateAvailabilityRevision, let target = dateAnchors[anchorDate] else {
            coverage = "该日没有可跳转的已同步记录"
            return
        }
        let jump = ChatHistorySearchJump(target: target, owner: owner, authority: jumpAuthority, hitID: nil, dateStatus: "found")
        guard canComplete(jump, context: context) else { return }
        onJump(jump)
    }

    func availableDates(in month: Date, calendar: Calendar, context: ChatHistorySearchPageContext) async -> Set<Date> {
        guard isPresented, owns(context), let monthInterval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let days = dayRange.compactMap { day -> DateInterval? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthInterval.start) else { return nil }
            return calendar.dateInterval(of: .day, for: date)
        }
        let revision = dateAvailabilityRevision
        let exclusions = dateVisibilityExclusions(context)
        let messages = await context.actions.dateMessages(context.conversationID, days,
            exclusions.ids, exclusions.sequences)
        guard !Task.isCancelled, isPresented, owns(context), revision == dateAvailabilityRevision else { return [] }
        var anchors: [String: RemoteTenantSearchJumpTarget] = [:]
        var dates: Set<Date> = []
        for message in messages.sorted(by: { $0.channelSeq < $1.channelSeq }) {
            guard let createdAt = message.createdAt else { continue }
            let date = calendar.startOfDay(for: createdAt)
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            guard anchors[key] == nil else { continue }
            guard !exclusions.ids.contains(message.id), !exclusions.sequences.contains(message.channelSeq) else { continue }
            anchors[key] = RemoteTenantSearchJumpTarget(kind: "message", channelID: context.conversationChannel,
                channelType: context.conversationChannelType, channelSeq: message.channelSeq, messageID: message.id)
            dates.insert(date)
        }
        dateAnchors = anchors
        dateAnchorsRevision = revision
        return dates
    }

    private func dateVisibilityExclusions(_ context: ChatHistorySearchPageContext) -> (ids: Set<String>, sequences: Set<Int64>) {
        var ids = locallyHiddenMessageIDs
        var sequences = locallyHiddenMessageSequences
        for event in invalidations.values where event.removesMessageDateVisibility {
            if let type = event.normalizedChannelType, let currentType = context.conversationChannelType,
               (type == "person" ? "direct" : type) != currentType { continue }
            let channel = event.normalizedChannelID
            if let channel, channel != context.conversationChannel && channel != context.conversationID { continue }
            if let id = event.normalizedMessageID { ids.insert(id) }
            if channel != nil, let sequence = event.channelSeq, sequence > 0 { sequences.insert(sequence) }
        }
        return (ids, sequences)
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    }

    func loadMore(_ context: ChatHistorySearchPageContext, retry: Bool = false) {
        guard isPresented, owns(context), let active, hasCurrentResponse, !busy, !paging, hasMore else { return }
        if let pageFailure {
            guard retry && pageFailure.canRetry else { return }
            if pageFailure == .cursorExpired {
                start(.first(active), immediate: true, context: context)
                return
            }
        }
        let capped = legacy["messages"].flatMap(Int.init).map { $0 > 1000 } ?? false
        let key = PageKey(messages: capped ? nil : legacy["messages"], files: legacy["files"], v2: messageCursorV2)
        if key == PageKey(messages: nil, files: nil, v2: nil) {
            hasMore = false
            if capped { pageFailure = .legacyPageLimit }
            return
        }
        guard retry || !consumedPages.contains(key) else { return }
        start(.page(active, key), immediate: true, context: context)
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
    func retry(_ context: ChatHistorySearchPageContext) {
        guard isPresented, owns(context), failure?.canRetry == true, let lastAttempt else { return }
        start(lastAttempt, immediate: true, context: context)
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    }

    func apply(_ event: SearchInvalidationEvent, context: ChatHistorySearchPageContext) {
        if invalidatesConversation(event, context: context) || !owns(context) {
            reset()
            return
        }
        invalidations[event.dedupeKey] = event
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
        dateAvailabilityRevision &+= 1
        revalidateVisibleHits(context)
    }

    func observeLocalMessageWindow(_ current: [ChatMessage], previous: [ChatMessage] = [],
                                   context: ChatHistorySearchPageContext) {
        guard owns(context) else { return }
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
        let hiddenCount = locallyHiddenMessageIDs.count + locallyHiddenMessageSequences.count
        // Remember confirmed visibility changes even when the timeline trims its window.
        for message in previous.lazy.filter(\.isHiddenFromConversationSearch) {
            rememberLocallyHiddenMessage(message)
        }
        for message in current.lazy.filter(\.isHiddenFromConversationSearch) {
            rememberLocallyHiddenMessage(message)
        }
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        if current.count != previous.count || current.last?.id != previous.last?.id ||
            hiddenCount != locallyHiddenMessageIDs.count + locallyHiddenMessageSequences.count {
            dateAvailabilityRevision &+= 1
        }
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        revalidateVisibleHits(context)
    }

    private func rememberLocallyHiddenMessage(_ message: ChatMessage) {
        if !message.id.isEmpty { locallyHiddenMessageIDs.insert(message.id) }
        if message.channelSeq > 0 { locallyHiddenMessageSequences.insert(message.channelSeq) }
    }

    private func revalidateVisibleHits(_ context: ChatHistorySearchPageContext) {
        guard owns(context), !results.isEmpty else { return }
        let filtered = admissible(results, context: context)
        guard filtered.count != results.count else { return }
        exactTotal = nil
        filteredMatches = true
        publish(filtered)
        if let focusedID, !results.contains(where: { $0.id == focusedID }) { self.focusedID = nil }
    }

    func invalidatesConversation(_ event: SearchInvalidationEvent, context: ChatHistorySearchPageContext) -> Bool {
        event.isTenantScopeReset || (event.isConversationRemoval &&
            (event.normalizedChannelID == context.conversationID || event.normalizedChannelID == context.conversationChannel))
    }

    func select(_ id: String, context: ChatHistorySearchPageContext) -> ChatHistorySearchJump? {
        guard isPresented, hasCurrentResponse, !busy, let active, let owner,
              let item = visibleItem(id, context: context), let target = item.jumpTarget else { return nil }
        context.actions.recordSearch(active.keyword, context.conversationID, owner)
        refreshHistory(context)
        track("click", work: .first(active), response: provenance[item.id], item: item, context: context)
        return .init(target: target, owner: owner, authority: jumpAuthority, hitID: id, dateStatus: nil)
    }

    func adjacent(_ delta: Int, context: ChatHistorySearchPageContext) -> ChatHistorySearchJump? {
        guard owns(context), let focusedPosition, let owner else { return nil }
        let index = focusedPosition + delta
        guard results.indices.contains(index), let item = visibleItem(results[index].id, context: context),
              let target = item.jumpTarget else { return nil }
        return .init(target: target, owner: owner, authority: jumpAuthority, hitID: item.id, dateStatus: nil)
    }

    func canComplete(_ jump: ChatHistorySearchJump, context: ChatHistorySearchPageContext) -> Bool {
        guard owns(context), jump.owner == owner, jump.authority == jumpAuthority,
              !isLocallyHidden(jump.target) else { return false }
        if let id = jump.hitID { return visibleItem(id, context: context) != nil }
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        let exclusions = dateVisibilityExclusions(context)
        return jump.target.messageID.map(exclusions.ids.contains) != true
            && jump.target.channelSeq.map(exclusions.sequences.contains) != true
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    }

    func finish(_ jump: ChatHistorySearchJump) { focusedID = jump.hitID }

    func removeRecent(_ term: String, context: ChatHistorySearchPageContext) {
        guard let owner, owns(context) else { return }
        context.actions.removeSearch(term, context.conversationID, owner)
        refreshHistory(context)
    }

    func clearRecent(_ context: ChatHistorySearchPageContext) {
        guard let owner, owns(context) else { return }
        context.actions.clearSearches(context.conversationID, owner)
        refreshHistory(context)
    }

    private func owns(_ context: ChatHistorySearchPageContext) -> Bool {
        owner == context.currentOwner() && conversationID == context.conversationID
    }

    private func refreshHistory(_ context: ChatHistorySearchPageContext) {
        if let owner, owns(context) { recent = context.actions.searchHistory(context.conversationID, owner) }
    }

    private func retire() {
        generation &+= 1
        task?.cancel()
        task = nil
        sent = nil
        busy = false
        paging = false
    }

    private func clearResults() {
        active = nil
        results.removeAll()
        rows.removeAll()
        presentations.removeAll()
        provenance.removeAll()
        legacy.removeAll()
        consumedPages.removeAll()
        totals.removeAll()
        limitedTypes.removeAll()
        filteredMatches = false
        messageCursorV2 = nil
        failure = nil
        pageFailure = nil
        coverage = nil
        exactTotal = nil
        hasMore = false
        focusedID = nil
        lastAttempt = nil
    }

    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
    private func start(_ work: Work, immediate: Bool, context: ChatHistorySearchPageContext) {
        if sent == work { return }
        if let sent, busy || paging {
            track("cancel", work: sent, response: nil, context: context)
        }
        retire()
        let ticket = generation
        lastAttempt = work
        let request: ChatHistorySearchRequest
        switch work {
        case .first(let query):
            failure = nil
            pageFailure = nil
            busy = true
            request = query.request(cursorV2: query.range.isMessageScoped ? "" : nil) // WDT_IOS1_SEARCH_LINK_FILTER_20261113
        case .page(let query, let key):
            pageFailure = nil
            paging = true
            request = query.request(legacy: key.legacy, cursorV2: key.v2)
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
        }
        task = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 550_000_000) }
            guard let self, current(ticket, work: work, context: context) else { return }
            sent = work
            let outcome = await context.actions.searchPage(request, context.conversationID)
            guard current(ticket, work: work, context: context) else { return }
            busy = false
            paging = false
            task = nil
            sent = nil
            switch outcome {
            case .retired: break
            case .failure(.access):
                jumpAuthority &+= 1
                clearResults()
                failure = .access
            case .failure(let error):
                if case .page = work { pageFailure = error } else { failure = error }
            case .response(let response):
                // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
                supportsLinks = response.supportsMessageLinks
                if request.hasLink && (!response.supportsMessageLinks || !response.appliedMessageLinkFilter) {
                    if case .page = work { pageFailure = .unavailable } else { failure = .unavailable }
                    return
                }
                // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
                // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
                supportsAttachmentMessages = response.supportsAttachmentMessages
                if request.messageContent != nil &&
                    (!response.supportsAttachmentMessages || !response.appliedAttachmentMessageFilter) {
                    if case .page = work { pageFailure = .unavailable } else { failure = .unavailable }
                    return
                }
                // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
                receive(response, work: work, types: request.types, context: context)
            }
        }
    }

    private func current(_ ticket: UInt64, work: Work, context: ChatHistorySearchPageContext) -> Bool {
        guard !Task.isCancelled, ticket == generation, isPresented, owns(context) else { return false }
        switch work {
        case .first(let key), .page(let key, _): return key == criteria
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        }
    }

    private func receive(_ response: RemoteTenantSearchResponse, work: Work, types: [String],
                         context: ChatHistorySearchPageContext) {
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
        if case .first(let query) = work {
            clearResults()
            active = query
        }
        let candidates = types.flatMap { response.resultsByType[$0]?.items ?? [] }
        let incoming = admissible(candidates, context: context)
        if incoming.count != candidates.count { filteredMatches = true }
        var merged = results
        var indexes = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })
        for hit in incoming {
            if let index = indexes[hit.id] {
                merged[index] = hit
            } else {
                indexes[hit.id] = merged.count
                merged.append(hit)
            }
            provenance[hit.id] = response
            presentations[hit.id] = nil
        }
        let pageState = TenantConversationSearchPaginationState(response: response, items: incoming)
        var messagesTooShort = false
        var unavailablePage = false
        for type in types {
            guard let bucket = response.resultsByType[type], bucket.status != "unavailable" else {
                if (response.resultsByType[type]?.error ?? response.errorsByType[type])?.code == "query_too_short" {
                    messagesTooShort = true
                }
                limitedTypes.insert(type)
                if case .page = work { unavailablePage = true }
                continue
            }
            let limited = bucket.authoritative == false || (type != "messages" && bucket.totalIsExact == false)
            if limited { limitedTypes.insert(type) } else { limitedTypes.remove(type) }
            legacy[type] = pageState.typeCursors[type]
            totals[type] = bucket.exactTotal
            if type == "messages" { messageCursorV2 = bucket.nextCursorV2 }
        }
        if case .page(_, let key) = work {
            if unavailablePage {
                pageFailure = .unavailable
            } else {
                consumedPages.insert(key)
                let next = PageKey(messages: legacy["messages"], files: legacy["files"], v2: messageCursorV2)
                if consumedPages.contains(next) {
                    legacy.removeAll()
                    messageCursorV2 = nil
                    pageFailure = .unavailable
                }
            }
        }
        hasMore = !legacy.isEmpty || messageCursorV2 != nil
        if hasMore { pageRevision &+= 1 }
        let requested = active?.range.types ?? types
        exactTotal = limitedTypes.isEmpty && requested.allSatisfy { totals[$0] != nil }
            && !filteredMatches ? requested.compactMap { totals[$0] }.reduce(0, +) : nil
        coverage = messagesTooShort ? "聊天记录需要至少 2 个字，仍可查找文件"
            : limitedTypes.isEmpty ? nil : "搜索结果覆盖有限"
        publish(admissible(merged, context: context))
        if !incoming.isEmpty {
            track("success", work: work, response: response, context: context)
        } else if case .first = work, limitedTypes.isEmpty {
            track("zero_result", work: work, response: response, context: context)
        }
    }

    private func admissible(_ hits: [RemoteTenantSearchResult], context: ChatHistorySearchPageContext) -> [RemoteTenantSearchResult] {
        context.actions.visibleHits(hits, context.conversationID).filter { hit in
            if let target = hit.jumpTarget, isLocallyHidden(target) { return false }
            if hit.type == "message" || hit.type == "messages" {
                let id = hit.resultID.hasPrefix("message:") ? String(hit.resultID.dropFirst("message:".count)) : hit.resultID
                if locallyHiddenMessageIDs.contains(id) { return false }
            }
            return !invalidations.values.contains { hit.matchesSearchInvalidation($0) }
        }
    }

    private func isLocallyHidden(_ target: RemoteTenantSearchJumpTarget) -> Bool {
        target.messageID.map(locallyHiddenMessageIDs.contains) == true ||
            target.channelSeq.map(locallyHiddenMessageSequences.contains) == true
    }

    private func visibleItem(_ id: String, context: ChatHistorySearchPageContext) -> RemoteTenantSearchResult? {
        guard owns(context), let hit = results.first(where: { $0.id == id }) else { return nil }
        return admissible([hit], context: context).first
    }

    private func publish(_ hits: [RemoteTenantSearchResult]) {
        let visibleIDs = Set(hits.map(\.id))
        for removed in results where !visibleIDs.contains(removed.id) {
            presentations[removed.id] = nil
            provenance[removed.id] = nil
        }
        results = hits
        rows = hits.map { hit in
            if let row = presentations[hit.id] { return row }
            let model = hit.displayModel
            let rawDate = hit.occurredAt ?? hit.sort["created_at"]?.stringValue
            let date = rawDate.flatMap { value in
                (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                    ?? (try? Date.ISO8601FormatStyle().parse(value))
            }
            let secondary = [hit.senderName ?? hit.source["sender_name"]?.stringValue,
                             date?.formatted(.dateTime.month().day().hour().minute())]
                .compactMap { $0 }.filter { !$0.isEmpty }
            let row = ChatHistorySearchResultPresentation(resultID: hit.resultID, type: hit.type,
                title: hit.title, subtitle: secondary.isEmpty ? model.secondaryText : secondary.joined(separator: " · "),
                snippet: hit.snippet,
                highlightRanges: hit.highlightRanges.map { .init(field: $0.field, start: $0.start, length: $0.length) },
                previewField: model.primaryField, displayKind: active?.range == .attachments ? "附件消息" : nil, select: {})
            presentations[hit.id] = row
            return row
        }
    }

    private func track(_ event: String, work: Work, response: RemoteTenantSearchResponse?,
                       item: RemoteTenantSearchResult? = nil, context: ChatHistorySearchPageContext) {
        guard owns(context) else { return }
        let query: ChatHistorySearchCriteria
        switch work {
        case .first(let criteria), .page(let criteria, _): query = criteria
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
        }
        let filters = Dictionary((response?.parsedFilters ?? []).map {
            ($0.key.isEmpty ? $0.type : $0.key, $0.value)
        }, uniquingKeysWith: { first, _ in first })
        context.actions.postTenantSearchEvent(TenantSearchAnalyticsEvent(
            searchID: response?.searchID, requestID: response?.requestID, eventType: event, scope: "conversation",
            types: response?.types.isEmpty == false ? (response?.types ?? query.range.types) : query.range.types,
            resultType: item?.type, resultID: item?.resultID, resultRank: item?.rank,
            queryLength: query.keyword.count, elapsedMS: response?.elapsedMS, filters: filters
        ))
    }
}

struct ChatHistorySearchPage: View {
    @ObservedObject var session: ChatHistorySearchSession
    @State private var focused = false
    let context: ChatHistorySearchPageContext
    let senders: [IMUser]
    let onClose: () -> Void
    let onJump: @MainActor (ChatHistorySearchJump) -> Void

    var body: some View {
        NavigationStackCompat {
            ChatHistorySearchPanel(keyword: $session.keyword, dateText: $session.anchorDate,
                results: session.rows, visibleResults: session.rows, total: session.exactTotal ?? 0,
                hitChannelSeqs: [], isSearching: session.busy, isLoadingMore: session.paging,
                hasMore: session.hasMore, searchFocus: $focused,
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
                onSearch: {
                    focused = false
                    session.update(immediate: true, remember: true, context: context)
                },
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
                onDateSearch: { session.jumpToDate(context, onJump: onJump) },
                onPrevious: {}, onNext: {}, onLoadMore: { session.loadMore(context) }, onClose: onClose,
                onSelect: { row in
                    if let jump = session.select("\(row.type):\(row.resultID)", context: context) { onJump(jump) }
                },
                onQueryChange: { session.update(context: context) },
                retainedQuery: session.retainedQuery,
                failureMessage: session.failure?.message,
                pageFailureMessage: session.pageFailure?.message,
                coverageMessage: session.coverage,
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
                onRetry: session.failure?.canRetry == true ? { session.retry(context) } : nil,
                onPageRetry: session.pageFailure?.canRetry == true ? { session.loadMore(context, retry: true) } : nil,
                hasCurrentResponse: session.hasCurrentResponse,
                fullScreen: true, extraFilters: AnyView(filters), recent: session.recent,
                onRecent: { value in
                    session.keyword = value
                    session.update(immediate: true, context: context)
                },
                onRemoveRecent: { session.removeRecent($0, context: context) },
                onClearRecent: { session.clearRecent(context) },
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
                automaticPageRevision: session.pageRevision,
                filterDate: session.filterDay,
                onFilterDate: { day in
                    session.filterDay = day
                    session.update(immediate: true, context: context)
                },
                dateAvailabilityRevision: session.dateAvailabilityRevision,
                loadAvailableDates: { month, calendar in
                    await session.availableDates(in: month, calendar: calendar, context: context)
                }
            )
            .navigationTitle("查找聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onClose)
                        .accessibilityIdentifier("chat_search_close_button")
                }
            }
                // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
            .accessibilityIdentifier("conversation_history_search_page")
        }
    }

    private var filters: some View {
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
        HStack(spacing: 8) {
            Menu {
        // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
                // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
                ForEach(ChatHistorySearchRange.allCases.filter { range in
                    (range != .links || session.supportsLinks)
                        && (range != .attachments || session.supportsAttachmentMessages)
                }) { range in
                    Button(range.title) { session.range = range; session.update(immediate: true, context: context) }
                }
                // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END
            // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
            } label: {
                filterLabel(session.range.title, icon: "line.3.horizontal.decrease")
            }
            if session.range.isMessageScoped && !senders.isEmpty { // WDT_IOS1_SEARCH_LINK_FILTER_20261113
                Menu {
                    Button("所有发送人") { session.sender = nil; session.update(immediate: true, context: context) }
                    ForEach(senders) { sender in
                        Button(sender.name) { session.sender = sender.id; session.update(immediate: true, context: context) }
                    }
                } label: {
                    filterLabel(senders.first(where: { $0.id == session.sender })?.name ?? "发送人", icon: "person")
                }
            }
        }
    }

    private func filterLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(IMColor.ink)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(minHeight: 38)
            .background(Capsule().fill(.white.opacity(0.92)))
            // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
    }
}

struct ChatHistorySearchLocator: View {
    @ObservedObject var session: ChatHistorySearchSession
    let move: (Int) -> Void
    let reopen: () -> Void

    var body: some View {
        if let index = session.focusedPosition {
            HStack(spacing: 12) {
                Text(session.exactTotal.map { "第 \(index + 1)/\($0) 条" } ?? "第 \(index + 1) 条 · 已加载 \(session.rows.count) 条")
                    .monospacedDigit()
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("上一条")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index + 1 == session.rows.count)
                    .accessibilityLabel("下一条")
                Button("返回结果", action: reopen)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .accessibilityIdentifier("conversation_history_search_locator")
        }
    }
}

extension ChatView {
    var historySearchContext: ChatHistorySearchPageContext {
        .init(actions: screenActions.search, conversationID: conversationID,
              conversationChannel: screenActions.history.remoteChannelID(for: conversation),
              // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
              conversationChannelType: ConversationChannelIdentityMapper.apiChannelType(for: conversation.kind),
              currentOwner: { screenActions.authority.chatBubbleSessionIdentity() })
    }

    var historySearchCover: some View {
        let candidates = conversation.kind == .group ? currentGroup.members : conversation.participants
        var ids = Set<String>()
        let senders = candidates.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }
        return ChatHistorySearchPage(session: historySearchSession, context: historySearchContext,
            senders: senders, onClose: closeHistorySearch, onJump: { selectHistorySearchJump($0) })
    }

    var historySearchLocator: some View {
        ChatHistorySearchLocator(session: historySearchSession, move: { delta in
            if let jump = historySearchSession.adjacent(delta, context: historySearchContext) { performHistorySearchJump(jump) }
        }, reopen: openHistorySearch)
    }

    func openHistorySearch() {
        cancelHistorySearchJump()
        let messages = screenStores.conversations.conversationMessageSnapshot(id: conversationID)?.messages ?? []
        historySearchSession.open(historySearchContext, currentMessages: messages)
        showSearch = true
    }

    func closeHistorySearch() {
        historySearchSession.close(historySearchContext)
        showSearch = false
    }

    func selectHistorySearchJump(_ jump: ChatHistorySearchJump) {
        guard showSearch, historySearchSession.canComplete(jump, context: historySearchContext) else { return }
        pendingHistorySearchJump = jump
        closeHistorySearch()
    }

    func historySearchDidDismiss() {
        historySearchSession.close(historySearchContext)
        if let jump = pendingHistorySearchJump {
            pendingHistorySearchJump = nil
            performHistorySearchJump(jump)
        }
    }

    func applyHistorySearchInvalidation(_ event: SearchInvalidationEvent) {
        historySearchSession.apply(event, context: historySearchContext)
        if historySearchSession.invalidatesConversation(event, context: historySearchContext) {
            pendingHistorySearchJump = nil
            cancelHistorySearchJump()
            showSearch = false
        } else if let pendingHistorySearchJump,
                  !historySearchSession.canComplete(pendingHistorySearchJump, context: historySearchContext) {
            self.pendingHistorySearchJump = nil
        }
    }

    func retireHistorySearchForAuthority(_ owner: ChatBubbleSessionIdentity) {
        guard let previous = historySearchSession.owner, previous != owner else { return }
        retireHistorySearch()
    }

    func retireHistorySearch() {
        historySearchSession.reset()
        pendingHistorySearchJump = nil
        cancelHistorySearchJump()
        showSearch = false
    }

    func cancelHistorySearchJump() {
        historySearchJumpGeneration &+= 1
        historySearchJumpTask?.cancel()
        historySearchJumpTask = nil
    }

    private func performHistorySearchJump(_ jump: ChatHistorySearchJump) {
        let context = historySearchContext
        guard historySearchSession.canComplete(jump, context: context) else { return }
        cancelHistorySearchJump()
        let generation = historySearchJumpGeneration
        historySearchJumpTask = Task { @MainActor in
            let target = await context.actions.prepareSearchJumpTarget(jump.target, conversationID: conversationID)
            guard !Task.isCancelled, generation == historySearchJumpGeneration, !showSearch,
                  historySearchSession.canComplete(jump, context: context) else { return }
            historySearchJumpTask = nil
            guard let target else {
                screenActions.toast("消息可能已删除、无权限或不可见")
                return
            }
            historySearchSession.finish(jump)
            setScrollTarget(target, source: .searchJump)
            if let status = jump.dateStatus {
                screenActions.toast(status == "nearest" ? "已定位到附近消息" : "已定位到当天消息")
            }
        }
    }
}
// WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END

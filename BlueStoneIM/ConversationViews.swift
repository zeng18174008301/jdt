import SwiftUI
import UIKit

enum ConversationListActivityDecision: Equatable {
    case none
    case scrollToTop
    case showHint
}

func conversationListActivityDecision(
    previousOrder: [String],
    nextOrder: [String],
    isNearTop: Bool,
    trackingEnabled: Bool = true
) -> ConversationListActivityDecision {
    guard trackingEnabled,
          !previousOrder.isEmpty,
          !nextOrder.isEmpty,
          previousOrder != nextOrder else {
        return .none
    }
    // 列表是顶部锚定的:用户在顶部附近时,重排后的最新会话本来就直接可见,
    // 不需要程序化 scrollTo。之前 isNearTop 时返回 .scrollToTop,实时消息频繁
    // 重排会反复触发动画回顶,真机上会打断正在进行的拖拽手势,表现为
    // “会话列表滑不动/刚下滑就被拉回顶部,下面的会话看不到”。
    return isNearTop ? .none : .showHint
}

func conversationListDisplayTimestamp(_ time: String, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
    let value = time.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value == "刚刚" {
        return now.timeIntervalSince1970
    }
    if value.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
        guard let timestamp = conversationListTimestampForTimeToken(value, dayOffset: 0, now: now, calendar: calendar) else {
            return nil
        }
        if timestamp > now.addingTimeInterval(60).timeIntervalSince1970,
           let adjustedDate = calendar.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: timestamp)) {
            return adjustedDate.timeIntervalSince1970
        }
        return timestamp
    }
    if let monthDayTimestamp = conversationListMonthDayTimestamp(in: value, now: now, calendar: calendar) {
        return monthDayTimestamp
    }
    if value.hasPrefix("昨天") {
        let token = value.split(separator: " ").map(String.init).last ?? ""
        return conversationListTimestampForTimeToken(token, dayOffset: -1, now: now, calendar: calendar)
            ?? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))?.timeIntervalSince1970
    }
    if value.hasPrefix("今天") {
        let token = value.split(separator: " ").map(String.init).last ?? ""
        return conversationListTimestampForTimeToken(token, dayOffset: 0, now: now, calendar: calendar)
    }
    return nil
}

func conversationListDisplayTime(for conversation: Conversation, now: Date = Date(), calendar: Calendar = .current) -> String {
    conversationListDisplayTime(rawTime: conversation.time, sortTimestamp: conversation.sortTimestamp, now: now, calendar: calendar)
}

// JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：列表行时间格式化支持轻量展示模型，避免把完整会话对象带入行视图
private func conversationListDisplayTime(rawTime: String, sortTimestamp: TimeInterval, now: Date = Date(), calendar: Calendar = .current) -> String {
    if sortTimestamp > 0 {
        let timestamp = conversationListNormalizedTimestamp(sortTimestamp, now: now, calendar: calendar)
        return conversationListDisplayTime(for: Date(timeIntervalSince1970: timestamp), now: now, calendar: calendar)
    }
    let normalizedRawTime = rawTime.trimmingCharacters(in: .whitespacesAndNewlines)
    if let timestamp = conversationListDisplayTimestamp(normalizedRawTime, now: now, calendar: calendar) {
        return conversationListDisplayTime(for: Date(timeIntervalSince1970: timestamp), now: now, calendar: calendar)
    }
    return normalizedRawTime
}
// JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

func conversationListNormalizedTimestamp(_ timestamp: TimeInterval, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
    guard timestamp > 0 else { return timestamp }
    let nowTimestamp = now.timeIntervalSince1970
    guard timestamp > nowTimestamp + 60 else { return timestamp }
    let date = Date(timeIntervalSince1970: timestamp)
    guard let adjusted = calendar.date(byAdding: .day, value: -1, to: date),
          adjusted.timeIntervalSince1970 <= nowTimestamp else {
        return timestamp
    }
    return adjusted.timeIntervalSince1970
}

private func conversationListDisplayTime(for date: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
        return ConversationListDateFormatterPool.string(from: date, format: "HH:mm", calendar: calendar)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "昨天 \(ConversationListDateFormatterPool.string(from: date, format: "HH:mm", calendar: calendar))"
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return ConversationListDateFormatterPool.string(from: date, format: "M月d日", calendar: calendar)
    } else {
        return ConversationListDateFormatterPool.string(from: date, format: "yyyy/M/d", calendar: calendar)
    }
}

private enum ConversationListDateFormatterPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, calendar: Calendar) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter = formatters[format] ?? {
            let value = DateFormatter()
            value.locale = Locale(identifier: "zh_CN")
            value.dateFormat = format
            formatters[format] = value
            return value
        }()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
}

private func conversationListMonthDayTimestamp(in value: String, now: Date, calendar: Calendar) -> TimeInterval? {
    let monthDayPattern = #"(\d{1,2})月(\d{1,2})日"#
    guard let match = value.range(of: monthDayPattern, options: .regularExpression) else { return nil }
    let numbers = String(value[match])
        .replacingOccurrences(of: "月", with: " ")
        .replacingOccurrences(of: "日", with: "")
        .split(separator: " ")
        .compactMap { Int($0) }
    guard numbers.count == 2 else { return nil }
    var components = calendar.dateComponents([.year], from: now)
    components.month = numbers[0]
    components.day = numbers[1]
    components.hour = 0
    components.minute = 0
    guard var date = calendar.date(from: components) else { return nil }
    if date > now, let previousYear = calendar.date(byAdding: .year, value: -1, to: date) {
        date = previousYear
    }
    return date.timeIntervalSince1970
}

private func conversationListTimestampForTimeToken(_ token: String, dayOffset: Int, now: Date, calendar: Calendar) -> TimeInterval? {
    let parts = token.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2,
          (0..<24).contains(parts[0]),
          (0..<60).contains(parts[1]) else {
        return nil
    }
    guard let baseDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)),
          let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: parts.count >= 3 ? parts[2] : 0, of: baseDay) else {
        return nil
    }
    return date.timeIntervalSince1970
}

func conversationListMessageJumpTarget(_ target: RemoteTenantSearchJumpTarget) -> RemoteTenantSearchJumpTarget? {
    let kind = target.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard kind != "conversation", kind != "conversations" else { return nil }
    let messageID = (target.messageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !messageID.isEmpty || (target.channelSeq ?? 0) > 0 else { return nil }
    return target
}

private struct ConversationListRoute: Identifiable, Hashable {
    let id = UUID()
    let conversationID: String
    let initialSearchJumpTarget: RemoteTenantSearchJumpTarget?

    static func == (lhs: ConversationListRoute, rhs: ConversationListRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private final class ConversationStoreChangeCoalescer {
    private var generation = 0
    private var isScheduled = false

    func begin() -> Int? {
        guard !isScheduled else { return nil }
        isScheduled = true
        generation += 1
        return generation
    }

    func finish(_ token: Int) -> Bool {
        guard isScheduled, token == generation else { return false }
        isScheduled = false
        return true
    }

    func cancelPending() {
        generation += 1
        isScheduled = false
    }
}

// JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_VIEW - 修改开始：会话列表渲染缓存与主线程卡顿检测
#if DEBUG
private enum ConversationListLagDiagnostics {
    static let hitchProbeIntervalNS: UInt64 = 250_000_000
    static let hitchProbeIntervalMS = 250

    static func elapsedMS(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    static func totalMessages(in conversations: [Conversation]) -> Int {
        conversations.reduce(0) { $0 + $1.messages.count }
    }

    static func logIfSlow(
        event: String,
        startedAt: Date,
        thresholdMS: Int,
        details: @autoclosure () -> String
    ) {
        let elapsed = elapsedMS(since: startedAt)
        guard elapsed >= thresholdMS else { return }
        let line = "[JHT Perf] conversation_list_lag event=\(event) elapsed_ms=\(elapsed) \(details())"
        print(line)
        ConversationListLagTraceRecorder.record(line)
    }
}
#endif
// JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_VIEW - 修改结束

struct ConversationListView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var filter = "全部"
    @State private var selectedConversationRoute: ConversationListRoute?
    @State private var selectedSearchFile: FileItem?
    @State private var actionConversation: Conversation?
    @State private var showEnterpriseSheet = false
    @State private var announcementIndex = 0
    @State private var selectedAnnouncement: InboxItem?
    @State private var cachedConversationSections: ConversationRenderSections = .empty
    // JHT_MOD_BEGIN CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改开始：缓存上一轮展示签名，避免无变化重建时重复扫描旧列表
    @State private var cachedConversationRenderSignature: [ConversationRenderSignature] = []
    // JHT_MOD_END CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改结束
    // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：缓存渲染输入签名，避免无变化时重复重建会话列表
    @State private var cachedConversationRenderInputSignature: ConversationRenderInputSignature?
    // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
    @State private var cachedMentionRecords: [MentionMessageRecord] = []
    @State private var cachedUnreadMentionCount = 0
    @State private var cachedAlertingUnreadTotal = 0
    @State private var cachedAnnouncementItems: [InboxItem] = []
    @State private var conversationCacheRebuildTask: Task<Void, Never>?
    @State private var conversationStoreChangeCoalescer = ConversationStoreChangeCoalescer()
    // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：聊天页覆盖列表时只记录 UI 缓存脏标记，避免不可见列表抢主线程重建
    @State private var conversationRenderCacheDirtyWhileRouteActive = false
    // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
    @State private var listClockTick = Date()
    @State private var hasBuiltInitialRenderCaches = false
    @State private var isNearConversationListTop = true
    @State private var showConversationActivityHint = false
    @State private var conversationListTopScrollRequest = 0
    @State private var globalSearchResponse: RemoteTenantSearchResponse?
    @State private var selectedGlobalSearchType: String?
    @State private var invalidatedGlobalSearchResultIDs: Set<String> = []
    @State private var globalSearchInvalidations: [SearchInvalidationEvent] = []
    @State private var isGlobalSearching = false
    @State private var isGlobalSearchLoadingMore = false
    @State private var globalSearchGeneration = 0
    @State private var globalSearchTask: Task<Void, Never>?
    // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_STATE - 修改开始：仅在会话列表可见时运行主线程延迟探针
    #if DEBUG
    @State private var conversationListHitchMonitorTask: Task<Void, Never>?
    #endif
    // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_STATE - 修改结束

    private let filters = ["全部", "未读", "@我"]
    private let tenantSearchSectionTypes = ["contacts", "groups", "conversations", "messages", "files"]
    private let conversationListTopAnchorID = "conversation-list-top-anchor"
    private let conversationListCoordinateSpaceName = "conversation-list-scroll"

    private func renderAlertingUnreadTotal() -> Int {
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：单次 reduce 统计提醒未读，避免 filter 生成临时数组
        state.conversations.reduce(0) { total, conversation in
            conversation.isMuted ? total : total + conversation.unread
        }
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    }

    private func renderAnnouncementItems() -> [InboxItem] {
        state.inboxItems.filter { item in
            !item.isRead && item.isAnnouncement
        }
    }

    private func renderMentionRecords() -> [MentionMessageRecord] {
        let records = state.conversations
            .flatMap { conversation -> [MentionMessageRecord] in
                let unreadMentions = unreadMentionMessages(in: conversation)
                // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：未读 mention 用 Set 判断，避免 @我 列表逐条 contains 扫描
                let unreadMentionIDs = Set(unreadMentions.map(\.id).filter { !$0.isEmpty })
                let hasUnreadMentionWithEmptyID = unreadMentions.contains { $0.id.isEmpty }
                // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
                var records = conversation.messages.enumerated().compactMap { index, message -> MentionMessageRecord? in
                    guard isMentionMessage(message), mentionMatchesQuery(message, in: conversation) else { return nil }
                    let sender = conversation.participants.first { $0.id == message.senderId }
                    let displaySenderName = mentionSenderDisplayName(for: message)
                    let isUnread = message.id.isEmpty
                        ? hasUnreadMentionWithEmptyID
                        : unreadMentionIDs.contains(message.id)
                    return MentionMessageRecord(
                        id: "\(conversation.id)-\(message.id)",
                        conversationID: conversation.id,
                        conversationTitle: conversationDisplayTitle(for: conversation),
                        conversationKind: conversation.kind,
                        messageID: message.id,
                        channelSeq: message.channelSeq,
                        senderUID: message.senderId,
                        senderName: displaySenderName,
                        senderSeed: sender?.avatarSeed ?? stableMentionSenderSeed(message.senderId.isEmpty ? message.senderName : message.senderId),
                        senderAvatarURL: message.senderAvatarURL,
                        senderAvatarVersion: message.senderAvatarVersion,
                        senderAvatarUpdatedAt: message.senderAvatarUpdatedAt,
                        text: message.text,
                        time: message.time,
                        isUnread: isUnread,
                        unreadCount: isUnread ? unreadMentions.count : 0,
                        sortScore: mentionSortScore(message: message, conversation: conversation, index: index)
                    )
                }
                if let summaryRecord = mentionSummaryRecord(in: conversation),
                   !records.contains(where: { record in
                       (!summaryRecord.messageID.isEmpty && record.messageID == summaryRecord.messageID)
                           || (summaryRecord.channelSeq > 0 && record.channelSeq == summaryRecord.channelSeq)
                   }) {
                    records.append(summaryRecord)
                }
                return records
            }
            .sorted { $0.sortScore > $1.sortScore }
        return Array(records.prefix(30))
    }

    private func renderUnreadMentionCount() -> Int {
        state.conversations.reduce(0) { total, conversation in
            // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：未读 mention 计数不再构造临时消息数组
            total + max(unreadMentionMessageCount(in: conversation), conversation.hasMention ? max(1, conversation.mentionCount) : 0)
            // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        }
    }

    private var matchingConversations: [Conversation] {
        let keyword = trimmedSearchQuery
        return state.conversations
            .filter { conversation in
                conversationMatchesCurrentList(conversation, keyword: keyword)
            }
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_RENDER_LOOP_PERF_20260912 - 修改开始：复用筛选判断，后续 render 可单次遍历构建列表
    private func conversationMatchesCurrentList(_ conversation: Conversation, keyword: String) -> Bool {
        let matchesFilter: Bool = {
            switch filter {
            case "未读": return conversation.unread > 0 && !conversation.isMuted
            case "@我": return false
            default: return true
            }
        }()
        guard matchesFilter else { return false }
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：无搜索词时跳过 mention 预览计算，避免普通滑动/刷新扫描消息数组
        if keyword.isEmpty {
            return true
        }
        if conversation.title.localizedCaseInsensitiveContains(keyword)
            || conversationDisplayTitle(for: conversation).localizedCaseInsensitiveContains(keyword)
            || conversation.lastMessage.localizedCaseInsensitiveContains(keyword) {
            return true
        }
        return latestUnreadMention(in: conversation)?.text.localizedCaseInsensitiveContains(keyword) == true
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    }
    // JHT_MOD_END CONVERSATION_LIST_RENDER_LOOP_PERF_20260912 - 修改结束

    var body: some View {
        let renderAnnouncementItems = cachedAnnouncementItems
        let renderMentionRecords = filter == "@我" ? cachedMentionRecords : []
        let conversationSections = filter == "@我" ? ConversationRenderSections.empty : cachedConversationSections
        let renderMatchingConversations = conversationSections.matching

        ZStack {
            AuroraBackground()
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Color.clear
                            .frame(height: 1)
                            .id(conversationListTopAnchorID)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ConversationListTopOffsetPreferenceKey.self,
                                        value: proxy.frame(in: .named(conversationListCoordinateSpaceName)).minY
                                    )
                                }
                            )

                        VStack(alignment: .leading, spacing: 18) {
                            ConversationTopCard(enterprise: state.currentEnterprise) {
                                showEnterpriseSheet = true
                            } openConversation: { conversationID in
                                openConversation(conversationID)
                            }
                            if state.networkBannerVisible && !renderAnnouncementItems.isEmpty {
                                AnnouncementBanner(
                                    items: renderAnnouncementItems,
                                    selection: $announcementIndex,
                                    selectedItem: $selectedAnnouncement
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                        Section {
                            filterBar
                                .padding(.horizontal, 18)
                                .padding(.bottom, 18)

                            if isGlobalSearchActive {
                                TenantGlobalSearchResultsView(
                                    query: trimmedSearchQuery,
                                    response: globalSearchResponse,
                                    excludedResultIDs: invalidatedGlobalSearchResultIDs,
                                    invalidations: globalSearchInvalidations,
                                    isLoading: isGlobalSearching,
                                    isLoadingMore: isGlobalSearchLoadingMore,
                                    selectedType: selectedGlobalSearchType,
                                    onSelectType: { type in
                                        selectedGlobalSearchType = type
                                        scheduleGlobalSearch()
                                    },
                                    onRemoveFilter: removeGlobalSearchFilter,
                                    onLoadMore: loadMoreGlobalSearchResults,
                                    onSelect: handleGlobalSearchSelection
                                )
                                .padding(.horizontal, 18)
                            } else if state.isInitialDataLoading && !state.hasLoadedRemoteSnapshot && state.conversations.isEmpty && filter != "@我" {
                                RemoteLoadingStateView(
                                    title: "正在同步会话",
                                    subtitle: "登录成功，正在立即拉取真实会话和最近消息。"
                                )
                                .padding(.horizontal, 18)
                            } else if let syncFailureMessage = state.syncFailureMessage, state.conversations.isEmpty, filter != "@我" {
                                EmptyStateView(
                                    symbol: "arrow.clockwise.icloud",
                                    title: "聊天数据同步失败",
                                    subtitle: syncFailureMessage,
                                    actionTitle: state.isSyncRetrying ? "正在重试..." : "重试同步"
                                ) {
                                    state.retryRemoteSync()
                                }
                                .padding(.horizontal, 18)
                            } else if filter == "@我" {
                                MentionMessageList(records: renderMentionRecords, mentionTarget: mentionTarget) { record in
                                    openConversation(
                                        record.conversationID,
                                        initialSearchJumpTarget: mentionJumpTarget(for: record)
                                    )
                                }
                                .padding(.horizontal, 18)
                            } else if renderMatchingConversations.isEmpty {
                                let isUnfilteredEmpty = trimmedSearchQuery.isEmpty && filter == "全部"
                                EmptyStateView(
                                    symbol: "bubble.left",
                                    title: isUnfilteredEmpty ? "暂无会话" : "没有匹配会话",
                                    subtitle: isUnfilteredEmpty ? "当前账号暂未返回可见会话。" : "换个关键词，或切换筛选条件查看全部会话。"
                                ) {
                                    query = ""
                                    filter = "全部"
                                }
                                .padding(.horizontal, 18)
                            } else {
                                // Keep one identity scope when a row moves into or out of pinning.
                                // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：复用缓存好的排序结果，避免 body 中反复拼接数组
                                ForEach(conversationSections.ordered) { item in
                                // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
                                    conversationRow(for: item)
                                        .padding(.horizontal, 18)
                                        .padding(.bottom, 12)
                                }
                            }
                            if !isGlobalSearchActive, filter != "@我", !state.conversations.isEmpty {
                                if state.isLoadingMoreConversations {
                                    HStack {
                                        ProgressView()
                                        Text("正在加载更多会话…")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else if state.isConversationSnapshotPartial {
                                    Button("部分会话尚未加载，点击重试") { state.retryRemoteSync() }
                                        .font(.caption)
                                        .disabled(state.isSyncRetrying)
                                }
                            }
                            Color.clear.frame(height: 12)
                        } header: {
                            PinnedSearchHeader {
                                SearchField(text: $query, placeholder: "搜索联系人、群聊、聊天记录、文件")
                                    .accessibilityIdentifier("conversation_search_field")
                            }
                        }
                    }
                }
                .coordinateSpace(name: conversationListCoordinateSpaceName)
                .onPreferenceChange(ConversationListTopOffsetPreferenceKey.self) { offset in
                    let isNearTop = offset > -96
                    guard isNearConversationListTop != isNearTop else { return }
                    isNearConversationListTop = isNearTop
                    if isNearTop {
                        showConversationActivityHint = false
                    }
                }
                .overlay(alignment: .top) {
                    conversationActivityHint(scrollProxy: scrollProxy)
                }
                .onChangeCompat(of: conversationListTopScrollRequest) { _, request in
                    guard request > 0 else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        scrollConversationListToTop(scrollProxy)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            PinnedSearchTopMask()
        }
        .onAppear {
            listClockTick = Date()
            // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_LIFECYCLE - 修改开始：进入会话列表时启动主线程卡顿探针
            #if DEBUG
            startConversationListHitchMonitor()
            #endif
            // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_LIFECYCLE - 修改结束
            applyNotificationConversationOpenRequest(state.notificationConversationOpenRequest)
            guard !hasBuiltInitialRenderCaches else { return }
            hasBuiltInitialRenderCaches = true
            rebuildAllRenderCaches()
        }
        .onReceive(state.conversationStore.$conversations) { _ in
            scheduleConversationStoreChangeHandling()
        }
        .onChangeCompat(of: state.inboxItems) { _, _ in
            rebuildAnnouncementCache()
        }
        .onChangeCompat(of: query) { _, _ in
            rebuildQueryDependentCaches()
            scheduleGlobalSearch()
        }
        .onChangeCompat(of: filter) { _, _ in
            rebuildQueryDependentCaches()
        }
        .onChangeCompat(of: state.currentUser.id) { _, _ in
            rebuildMentionCache(includeRecords: filter == "@我")
        }
        .onChangeCompat(of: state.currentUser.name) { _, _ in
            rebuildQueryDependentCaches()
        }
        .onChangeCompat(of: state.contactRemarks) { _, _ in
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：备注会影响直聊展示名，强制刷新渲染输入签名
            invalidateConversationRenderInputSignature()
            // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
            scheduleConversationRenderCacheRebuild()
        }
        // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_REFRESH - 修改开始：联系人/认证展示变化时刷新列表行缓存
        .onReceive(state.contactStore.$contacts) { _ in
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：联系人资料会影响直聊头像和展示名，强制刷新渲染输入签名
            invalidateConversationRenderInputSignature()
            // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
            scheduleConversationRenderCacheRebuild()
        }
        .onChangeCompat(of: state.certificationPresentationRevision) { _, _ in
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：认证展示变化会影响行内角标，强制刷新渲染输入签名
            invalidateConversationRenderInputSignature()
            // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
            scheduleConversationRenderCacheRebuild()
        }
        // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRESENTATION_REFRESH - 修改结束：联系人/认证展示变化时刷新列表行缓存
        .onChangeCompat(of: selectedConversationRoute) { _, newValue in
            // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：进入聊天页取消待执行列表重建，返回时补一次最新缓存
            if newValue == nil {
                conversationRenderCacheDirtyWhileRouteActive = false
                scheduleConversationRenderCacheRebuild()
            } else if conversationCacheRebuildTask != nil {
                markConversationRenderCacheDirtyWhileRouteActive(reason: "route_presented")
            }
            // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
        }
        .onChangeCompat(of: state.searchInvalidationRevision) { _, _ in
            applyLatestSearchInvalidationToGlobalResults()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                listClockTick = now
            }
        }
        .onDisappear {
            if isGlobalSearching || isGlobalSearchLoadingMore {
                postGlobalSearchAnalytics(eventType: "cancel", response: globalSearchResponse)
            }
            conversationStoreChangeCoalescer.cancelPending()
            conversationCacheRebuildTask?.cancel()
            conversationCacheRebuildTask = nil
            // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_STOP - 修改开始：离开会话列表时停止卡顿探针
            #if DEBUG
            stopConversationListHitchMonitor()
            #endif
            // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_STOP - 修改结束
            globalSearchTask?.cancel()
            globalSearchTask = nil
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            ChatView(
                conversationID: route.conversationID,
                initialSearchJumpTarget: route.initialSearchJumpTarget
            )
        }
        .onChangeCompat(of: state.conversationListReturnToken) { _, token in
            // 退群/解散群成功:关闭当前会话页(其上的群详情/确认弹窗随之收起),
            // 直接回到会话列表。
            guard token > 0 else { return }
            selectedConversationRoute = nil
        }
        .onChangeCompat(of: state.notificationConversationOpenRequest) { _, request in
            applyNotificationConversationOpenRequest(request)
        }
        .sheet(isPresented: $showEnterpriseSheet) {
            EnterpriseSwitcherView()
                .presentationDetentsCompat([.medium, .large])
        }
        .alert(item: $selectedAnnouncement) { item in
            Alert(
                title: Text(item.title),
                message: Text("\(item.normalizedCategory) · \(item.time)\n\n\(item.subtitle)"),
                primaryButton: .default(Text("标记已读")) {
                    state.markInboxRead(item.id)
                },
                secondaryButton: .cancel(Text("关闭"))
            )
        }
        .sheet(item: $actionConversation) { conversation in
            ConversationActionSheet(conversationID: conversation.id)
                .environmentObject(state)
                .presentationDetentsCompat([.height(292)])
                .presentationDragIndicatorCompat(.hidden)
                .presentationCornerRadiusCompat(30)
                .presentationBackgroundClearCompat()
        }
        .sheet(item: $selectedSearchFile) { file in
            FilePreviewView(file: file)
                .environmentObject(state)
        }
    }

    private func conversationRow(for item: ConversationRenderItem) -> some View {
        let conversation = item.conversation
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：交互行使用轻量展示模型，点击/长按仍沿用原会话业务对象
        let rowModel = item.rowModel
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        return ConversationInteractiveRow(
            rowModel: rowModel,
            mentionTarget: mentionTarget,
            unreadMention: item.unreadMention,
            systemNoticeAvatarURL: state.systemNoticeAvatarURL
        ) {
            if conversation.kind == .system, conversation.unread > 0 {
                state.markConversationRead(conversation.id, showToast: false)
            }
            openConversation(
                conversation.id,
                initialSearchJumpTarget: earliestUnreadMentionJumpTarget(in: conversation)
            )
        } onLongPress: {
            guard conversationListSupportsMutableActions(conversation) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            actionConversation = conversation
        }
        .equatable()
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_MONITOR - 修改开始：检测会话列表可见期间主线程被阻塞的时间片
    #if DEBUG
    private func startConversationListHitchMonitor() {
        conversationListHitchMonitorTask?.cancel()
        conversationListHitchMonitorTask = Task { @MainActor in
            var lastTick = Date()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: ConversationListLagDiagnostics.hitchProbeIntervalNS)
                } catch {
                    return
                }
                let now = Date()
                let elapsedMS = max(0, Int(now.timeIntervalSince(lastTick) * 1_000))
                let driftMS = elapsedMS - ConversationListLagDiagnostics.hitchProbeIntervalMS
                if driftMS >= 120 {
                    let line = "[JHT Perf] conversation_list_hitch drift_ms=\(driftMS) interval_ms=\(elapsedMS) visible_count=\(cachedConversationSections.matching.count) source_count=\(state.conversations.count) total_messages=\(ConversationListLagDiagnostics.totalMessages(in: state.conversations)) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
                    print(line)
                    ConversationListLagTraceRecorder.record(line)
                }
                lastTick = now
            }
        }
    }

    private func stopConversationListHitchMonitor() {
        conversationListHitchMonitorTask?.cancel()
        conversationListHitchMonitorTask = nil
    }
    #endif
    // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_MONITOR - 修改结束

    @ViewBuilder
    private func conversationActivityHint(scrollProxy: ScrollViewProxy) -> some View {
        if showConversationActivityHint && filter != "@我" && query.isEmpty {
            Button {
                scrollConversationListToTop(scrollProxy)
            } label: {
                Label("有新会话", systemImage: "arrow.up.circle.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(IMColor.brand))
                    .overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 1))
                    .shadow(color: IMColor.brand.opacity(0.24), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 66)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("conversation_new_activity_hint")
            .accessibilityLabel("有新会话，回到顶部")
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showConversationActivityHint)
        }
    }

    private func openConversation(
        _ conversationID: String,
        initialSearchJumpTarget: RemoteTenantSearchJumpTarget? = nil
    ) {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        selectedConversationRoute = ConversationListRoute(
            conversationID: normalizedID,
            initialSearchJumpTarget: initialSearchJumpTarget
        )
    }

    private func applyNotificationConversationOpenRequest(
        _ request: IOSNotificationConversationOpenRequest?
    ) {
        guard let request else { return }
        openConversation(
            request.conversationID,
            initialSearchJumpTarget: request.jumpTarget
        )
        state.consumeNotificationConversationOpenRequest(request.id)
    }

    private func scrollConversationListToTop(_ scrollProxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            scrollProxy.scrollTo(conversationListTopAnchorID, anchor: .top)
        }
        showConversationActivityHint = false
        isNearConversationListTop = true
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("早上好，\(state.currentUser.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: state.currentUser.id,
                        compact: true
                    )
                }
                Text("企业 IM 工作台")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(IMColor.ink)
            }
            Spacer()
            AvatarView(name: state.currentUser.name, seed: state.currentUser.avatarSeed, size: 48, imageURL: state.currentUser.avatarURL, avatarVersion: state.currentUser.avatarVersion, avatarUpdatedAt: state.currentUser.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: state.currentUser.id))
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            ForEach(filters, id: \.self) { item in
                Button {
                    filter = item
                } label: {
                    Chip(
                        title: item,
                        isSelected: filter == item,
                        count: filterCount(for: item),
                        countColor: item == "@我" ? IMColor.danger : IMColor.brand,
                        countFilled: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation_filter_\(item)")
                .accessibilityLabel("筛选 \(item)")
            }
        }
    }

    private var trimmedSearchQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isGlobalSearchActive: Bool {
        !trimmedSearchQuery.isEmpty && filter != "@我"
    }

    private func scheduleGlobalSearch() {
        if globalSearchTask != nil, isGlobalSearching {
            postGlobalSearchAnalytics(eventType: "cancel", response: globalSearchResponse)
        }
        globalSearchTask?.cancel()
        let keyword = trimmedSearchQuery
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        guard !keyword.isEmpty, filter != "@我" else {
            globalSearchResponse = nil
            isGlobalSearching = false
            isGlobalSearchLoadingMore = false
            return
        }
        isGlobalSearching = true
        let selectedType = selectedGlobalSearchType
        let requestTypes = selectedType.map { [$0] } ?? tenantSearchSectionTypes
        globalSearchTask = Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            let response = await state.tenantSearch(
                query: keyword,
                scope: "global",
                types: requestTypes,
                limit: selectedType == nil ? 10 : 20
            )
            await MainActor.run {
                guard generation == globalSearchGeneration, trimmedSearchQuery == keyword else { return }
                globalSearchResponse = response
                isGlobalSearching = false
                if let response {
                    postGlobalSearchAnalytics(eventType: globalSearchHasResults(response) ? "success" : "zero_result", response: response)
                }
            }
        }
    }

    private func handleGlobalSearchSelection(_ item: RemoteTenantSearchResult) {
        guard !item.isBlockedFromChatSearchDisplay else {
            state.toast = "该消息不可查看"
            return
        }
        postGlobalSearchAnalytics(eventType: "click", response: globalSearchResponse, item: item)
        guard let target = item.jumpTarget else {
            state.toast = "搜索结果暂不可跳转"
            return
        }
        if let conversationID = state.conversationID(for: target) {
            openConversation(
                conversationID,
                initialSearchJumpTarget: conversationListMessageJumpTarget(target)
            )
            return
        }
        switch target.kind {
        case "user_profile":
            state.toast = "联系人详情稍后接入"
        case "file", "message_file":
            openSearchFileDetail(target: target, item: item)
        default:
            state.toast = "未找到来源会话"
        }
    }

    private func openSearchFileDetail(target: RemoteTenantSearchJumpTarget, item: RemoteTenantSearchResult) {
        let fallbackFileID = item.resultID.hasPrefix("file:") ? String(item.resultID.dropFirst(5)) : item.resultID
        let fileID = (target.fileID ?? fallbackFileID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else {
            state.toast = "未找到文件编号"
            return
        }
        Task {
            let file = await state.fileItemForSearchResult(fileID: fileID, fallbackName: item.title)
            await MainActor.run {
                if let file {
                    selectedSearchFile = file
                }
            }
        }
    }

    private func loadMoreGlobalSearchResults(_ type: String) {
        guard !isGlobalSearchLoadingMore,
              let response = globalSearchResponse,
              let cursor = response.resultsByType[type]?.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cursor.isEmpty else { return }
        let keyword = trimmedSearchQuery
        guard !keyword.isEmpty else { return }
        isGlobalSearchLoadingMore = true
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        globalSearchTask?.cancel()
        globalSearchTask = Task {
            let nextResponse = await state.tenantSearch(
                query: keyword,
                scope: "global",
                types: [type],
                limit: 20,
                cursor: cursor,
                typeCursors: [type: cursor]
            )
            await MainActor.run {
                guard generation == globalSearchGeneration, trimmedSearchQuery == keyword else { return }
                if let nextResponse {
                    globalSearchResponse = mergedGlobalSearchResponse(current: response, next: nextResponse, appendingType: type)
                    postGlobalSearchAnalytics(eventType: "success", response: nextResponse)
                }
                isGlobalSearchLoadingMore = false
            }
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
        buckets[type] = RemoteTenantSearchBucket(
            items: mergedItems,
            count: max(nextBucket.count, mergedItems.count),
            hasMore: nextBucket.hasMore,
            nextCursor: nextBucket.nextCursor
        )
        return RemoteTenantSearchResponse(
            query: next.query.isEmpty ? current.query : next.query,
            scope: next.scope.isEmpty ? current.scope : next.scope,
            types: current.types,
            limit: next.limit,
            searchID: next.searchID ?? current.searchID,
            requestID: next.requestID ?? current.requestID,
            elapsedMS: next.elapsedMS,
            resultsByType: buckets,
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

    private func globalSearchHasResults(_ response: RemoteTenantSearchResponse) -> Bool {
        tenantSearchSectionTypes.contains { type in
            visibleTenantSearchItems(response.resultsByType[type]?.items ?? []).isEmpty == false
        } || !visibleTenantSearchItems(response.items).isEmpty
    }

    private func removeGlobalSearchFilter(_ filter: RemoteTenantSearchParsedFilter) {
        let candidates = [
            filter.raw,
            filter.operatorName.map { "\($0):\(filter.value)" },
            filter.key.isEmpty ? nil : "\(filter.key):\(filter.value)"
        ]
        let original = query
        var updated = query
        for candidate in candidates {
            guard let token = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { continue }
            updated = updated.replacingOccurrences(of: token, with: "", options: [.caseInsensitive])
        }
        updated = updated
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if updated == original {
            state.toast = "请直接编辑搜索关键词调整筛选"
        } else {
            query = updated
        }
    }

    private func postGlobalSearchAnalytics(
        eventType: String,
        response: RemoteTenantSearchResponse?,
        item: RemoteTenantSearchResult? = nil
    ) {
        let filterPairs = (response?.parsedFilters ?? []).map { filter in
            (filter.key.isEmpty ? filter.type : filter.key, filter.value)
        }
        let filterSummary = Dictionary(filterPairs, uniquingKeysWith: { first, _ in first })
        state.postTenantSearchEvent(TenantSearchAnalyticsEvent(
            searchID: response?.searchID,
            requestID: response?.requestID,
            eventType: eventType,
            scope: response?.scope.isEmpty == false ? response?.scope ?? "global" : "global",
            types: selectedGlobalSearchType.map { [$0] } ?? tenantSearchSectionTypes,
            resultType: item?.type,
            resultID: item?.resultID,
            resultRank: item?.rank,
            queryLength: trimmedSearchQuery.count,
            elapsedMS: response?.elapsedMS,
            filters: filterSummary
        ))
    }

    private func applyLatestSearchInvalidationToGlobalResults() {
        guard let invalidation = state.latestSearchInvalidation else { return }
        if invalidation.isTenantScopeReset {
            globalSearchTask?.cancel()
            globalSearchResponse = nil
            invalidatedGlobalSearchResultIDs.removeAll()
            globalSearchInvalidations.removeAll()
            isGlobalSearching = false
            return
        }
        globalSearchInvalidations.append(invalidation)
        if globalSearchInvalidations.count > 64 {
            globalSearchInvalidations.removeFirst(globalSearchInvalidations.count - 64)
        }
        guard let response = globalSearchResponse else { return }
        let matchingIDs = response.resultsByType.values
            .flatMap(\.items)
            .filter { $0.matchesSearchInvalidation(invalidation) }
            .map(\.id)
        guard !matchingIDs.isEmpty else { return }
        invalidatedGlobalSearchResultIDs.formUnion(matchingIDs)
    }

    private func filterCount(for item: String) -> Int? {
        switch item {
        case "全部":
            cachedAlertingUnreadTotal > 0 ? cachedAlertingUnreadTotal : nil
        case "未读":
            cachedAlertingUnreadTotal > 0 ? cachedAlertingUnreadTotal : nil
        case "@我":
            cachedUnreadMentionCount > 0 ? cachedUnreadMentionCount : nil
        default:
            nil
        }
    }

    private var mentionTarget: String {
        "@\(state.currentUser.name)"
    }

    private func isMentionMessage(_ message: ChatMessage) -> Bool {
        MessageMentionProjection.includes(message, currentActor: state.currentUser)
    }

    private func mentionSummaryRecord(in conversation: Conversation) -> MentionMessageRecord? {
        guard conversation.hasMention,
              !conversation.mentionSummaryText.isEmpty,
              mentionSummaryMatchesQuery(conversation) else { return nil }
        let directPeer = conversation.kind == .direct
            ? state.directConversationProfilePeer(for: conversation)
            : nil
        return MentionMessageRecord(
            id: "\(conversation.id)-mention-summary-\(conversation.mentionSummaryMessageID.isEmpty ? String(conversation.mentionSummaryChannelSeq) : conversation.mentionSummaryMessageID)",
            conversationID: conversation.id,
            conversationTitle: conversationDisplayTitle(for: conversation),
            conversationKind: conversation.kind,
            messageID: conversation.mentionSummaryMessageID,
            channelSeq: conversation.mentionSummaryChannelSeq,
            senderUID: "",
            senderName: conversationDisplayTitle(for: conversation),
            senderSeed: stableMentionSenderSeed(conversation.id),
            senderAvatarURL: conversation.kind == .group ? conversation.avatarURL : directPeer?.displayAvatarURL ?? "",
            senderAvatarVersion: conversation.kind == .group ? conversation.avatarVersion : directPeer?.avatarVersion ?? "",
            senderAvatarUpdatedAt: conversation.kind == .group ? conversation.avatarUpdatedAt : directPeer?.avatarUpdatedAt ?? "",
            text: conversation.mentionSummaryText,
            time: conversation.time,
            isUnread: true,
            unreadCount: max(1, conversation.mentionCount),
            sortScore: Int(conversation.mentionSummaryChannelSeq) + 90_000
        )
    }

    private func mentionJumpTarget(for record: MentionMessageRecord) -> RemoteTenantSearchJumpTarget? {
        let messageID = record.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelSeq = record.channelSeq > 0 ? record.channelSeq : nil
        guard !messageID.isEmpty || channelSeq != nil else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: record.conversationID,
            channelType: mentionJumpChannelType(record.conversationKind),
            channelSeq: channelSeq,
            messageID: messageID.isEmpty ? nil : messageID
        )
    }

    private func mentionJumpChannelType(_ kind: ConversationKind) -> String {
        switch kind {
        case .group: return "group"
        case .system: return "system"
        case .direct: return "direct"
        }
    }

    private func mentionSummaryMatchesQuery(_ conversation: Conversation) -> Bool {
        let keyword = trimmedSearchQuery
        guard !keyword.isEmpty else { return true }
        let displayTitle = conversationDisplayTitle(for: conversation)
        return conversation.mentionSummaryText.localizedCaseInsensitiveContains(keyword)
            || conversation.title.localizedCaseInsensitiveContains(keyword)
            || displayTitle.localizedCaseInsensitiveContains(keyword)
    }

    private func mentionMatchesQuery(_ message: ChatMessage, in conversation: Conversation) -> Bool {
        let keyword = trimmedSearchQuery
        guard !keyword.isEmpty else { return true }
        let displayTitle = conversationDisplayTitle(for: conversation)
        return message.text.localizedCaseInsensitiveContains(keyword)
            || mentionSenderDisplayName(for: message).localizedCaseInsensitiveContains(keyword)
            || conversation.title.localizedCaseInsensitiveContains(keyword)
            || displayTitle.localizedCaseInsensitiveContains(keyword)
    }

    private func mentionSortScore(message: ChatMessage, conversation: Conversation, index: Int) -> Int {
        let source = "\(conversation.time) \(message.time)"
        let dayBase: Int
        if source.contains("刚刚") {
            dayBase = 50_000
        } else if source.contains("今天") || (source.contains(":") && !source.contains("周一") && !source.contains("昨天")) {
            dayBase = 40_000
        } else if source.contains("昨天") {
            dayBase = 30_000
        } else if source.contains("周一") {
            dayBase = 10_000
        } else {
            dayBase = 0
        }
        return dayBase + timeMinutes(in: source) + index
    }

    private func stableMentionSenderSeed(_ value: String) -> UInt {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt = 2_166_136_261
        for byte in normalized.utf8 {
            hash ^= UInt(byte)
            hash &*= 16_777_619
        }
        return hash
    }

    private func timeMinutes(in text: String) -> Int {
        for token in text.split(separator: " ") where token.contains(":") {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { continue }
            return hour * 60 + minute
        }
        return 0
    }

    private func conversationDisplaySortScore(_ time: String) -> Int {
        if time.contains("刚刚") { return 50_000 }
        if time.contains(":") && !time.contains("昨天") && !time.contains("周") && !time.contains("月") {
            return 40_000 + timeMinutes(in: time)
        }
        if time.contains("昨天") {
            return 30_000 + timeMinutes(in: time)
        }
        let monthDayPattern = #"(\d{1,2})月(\d{1,2})日"#
        if let match = time.range(of: monthDayPattern, options: .regularExpression) {
            let value = String(time[match])
            let parts = value
                .replacingOccurrences(of: "月", with: " ")
                .replacingOccurrences(of: "日", with: "")
                .split(separator: " ")
                .compactMap { Int($0) }
            if parts.count == 2 {
                return parts[0] * 100 + parts[1]
            }
        }
        return 0
    }

    private func conversationSortScore(_ conversation: Conversation) -> Double {
        if conversation.sortTimestamp > 0 {
            return conversationListNormalizedTimestamp(conversation.sortTimestamp, now: listClockTick)
        }
        if let displayTimestamp = conversationListDisplayTimestamp(conversation.time, now: listClockTick) {
            return displayTimestamp
        }
        return Double(conversationDisplaySortScore(conversation.time))
    }

    private func sortedConversationItems(_ items: [ConversationRenderItem]) -> [ConversationRenderItem] {
        items.sorted { lhs, rhs in
            let lhsScore = lhs.sortScore
            let rhsScore = rhs.sortScore
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.rowModel.id < rhs.rowModel.id
        }
    }

    private func conversationDisplayTitle(for conversation: Conversation) -> String {
        if conversation.kind == .direct,
           let participant = state.directConversationProfilePeer(for: conversation) {
            return state.remarkPreferredDisplayName(for: participant)
        }
        return conversation.title
    }

    private func renderConversationSections() -> ConversationRenderSections {
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_RENDER_SECTIONS - 修改开始：记录会话列表筛选、展示字段预计算、排序耗时
        #if DEBUG
        let renderStartedAt = Date()
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_RENDER_SECTIONS - 修改结束
        let keyword = trimmedSearchQuery
        let contactLookup = DirectConversationCallPeerResolver.ContactLookup(contacts: state.contacts)
        // JHT_MOD_BEGIN CONVERSATION_LIST_DIRECT_IDENTITY_CACHE_PERF_20260912 - 修改开始：本轮渲染复用当前身份集合，避免每条私聊会话重复构造 Set
        let currentProfileIdentityIDs = state.currentUserIdentitySet()
        var directResolverCurrentIdentityIDs = Set(state.userIdentityCandidates(for: state.currentUser))
        if let imUID = state.apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !imUID.isEmpty {
            directResolverCurrentIdentityIDs.insert(imUID)
        }

        func isCurrentUserProfileForRender(_ user: IMUser) -> Bool {
            state.userIdentityCandidates(for: user).contains { currentProfileIdentityIDs.contains($0) }
        }

        func directConversationProfilePeerForRender(_ conversation: Conversation) -> IMUser? {
            guard let peer = DirectConversationProfilePeerResolver.resolve(
                conversation: conversation,
                currentIdentityIDs: directResolverCurrentIdentityIDs,
                contacts: state.contacts,
                fallbackEnterprise: state.currentEnterprise.name,
                contactLookup: contactLookup
            ), !isCurrentUserProfileForRender(peer) else {
                return nil
            }
            return peer
        }

        func firstUniqueDirectPeerIDForRender(_ rawIDs: [String]) -> String? {
            var seen = Set<String>()
            let peerIDs = rawIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !currentProfileIdentityIDs.contains($0) }
                .filter { seen.insert($0).inserted }
            return peerIDs.count == 1 ? peerIDs[0] : nil
        }

        func directConversationCertificationUIDForRender(_ conversation: Conversation, resolvedPeer: IMUser?) -> String? {
            guard conversation.kind == .direct else { return nil }

            if let peer = resolvedPeer,
               let uid = state.userIdentityCandidates(for: peer).first(where: { !currentProfileIdentityIDs.contains($0) }) {
                return uid
            }

            if let uid = firstUniqueDirectPeerIDForRender(conversation.participants.map(\.id)) {
                return uid
            }

            if let uid = firstUniqueDirectPeerIDForRender(
                state.directChannelParts(state.remoteChannelID(for: conversation)) + state.directChannelParts(conversation.id)
            ) {
                return uid
            }

            return conversation.messages.reversed().lazy
                .map(\.senderId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !currentProfileIdentityIDs.contains($0) }
        }
        // JHT_MOD_END CONVERSATION_LIST_DIRECT_IDENTITY_CACHE_PERF_20260912 - 修改结束
        // JHT_MOD_BEGIN CONVERSATION_LIST_RENDER_LOOP_PERF_20260912 - 修改开始：单次遍历完成筛选、行模型构建和置顶分组，减少大列表主线程数组 churn
        var matching: [ConversationRenderItem] = []
        var pinned: [ConversationRenderItem] = []
        var regular: [ConversationRenderItem] = []
        matching.reserveCapacity(state.conversations.count)
        pinned.reserveCapacity(state.conversations.count / 8)
        regular.reserveCapacity(state.conversations.count)
        for conversation in state.conversations {
            guard conversationMatchesCurrentList(conversation, keyword: keyword) else { continue }
            // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_BUILD - 修改开始：会话列表行展示数据提前缓存，减少滑动时逐行查全局状态
            let directPeer = conversation.kind == .direct
                ? directConversationProfilePeerForRender(conversation)
                : nil
            let displayTitle: String = {
                guard conversation.kind == .direct, let directPeer else {
                    return conversation.title
                }
                return state.remarkPreferredDisplayName(for: directPeer)
            }()
            let directCertificationUID = conversation.kind == .direct
                ? (directConversationCertificationUIDForRender(conversation, resolvedPeer: directPeer) ?? directPeer?.id ?? "")
                : ""
            let directCertificationPresentation = directCertificationUID.isEmpty
                ? nil
                : state.certificationPresentation(forExactUID: directCertificationUID)
            let rowPresentation: ConversationRowPresentation = {
                switch conversation.kind {
                case .direct:
                    return ConversationRowPresentation(
                        avatarURL: directPeer?.displayAvatarURL ?? "",
                        avatarVersion: directPeer?.avatarVersion ?? "",
                        avatarUpdatedAt: directPeer?.avatarUpdatedAt ?? "",
                        avatarImageCacheKey: "",
                        directCertificationUID: directCertificationUID,
                        directCertificationPresentation: directCertificationPresentation
                    )
                case .group:
                    return ConversationRowPresentation(
                        avatarURL: conversation.avatarURL,
                        avatarVersion: conversation.avatarVersion,
                        avatarUpdatedAt: conversation.avatarUpdatedAt,
                        avatarImageCacheKey: state.groupAvatarCacheKey(for: conversation),
                        directCertificationUID: "",
                        directCertificationPresentation: nil
                    )
                case .system:
                    return ConversationRowPresentation(
                        avatarURL: "",
                        avatarVersion: "",
                        avatarUpdatedAt: "",
                        avatarImageCacheKey: "",
                        directCertificationUID: "",
                        directCertificationPresentation: nil
                    )
                }
            }()
            // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRESENTATION_BUILD - 修改结束：会话列表行展示数据提前缓存，减少滑动时逐行查全局状态
            let item = ConversationRenderItem(
                conversation: conversation,
                displayTitle: displayTitle,
                unreadMention: latestUnreadMention(in: conversation),
                sortScore: conversationSortScore(conversation),
                rowPresentation: rowPresentation,
                // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：预构建轻量行模型，滚动渲染不再持有完整消息数组
                rowModel: ConversationRowModel(
                    id: conversation.id,
                    kind: conversation.kind,
                    displayTitle: displayTitle,
                    lastMessage: conversation.lastMessage,
                    time: conversation.time,
                    unread: conversation.unread,
                    isPinned: conversation.isPinned,
                    isMuted: conversation.isMuted,
                    accentHex: conversation.accentHex,
                    hasUnreadReaction: conversation.hasUnreadReaction,
                    unreadReactionCount: conversation.unreadReactionCount,
                    sortTimestamp: conversation.sortTimestamp,
                    rowPresentation: rowPresentation
                )
                // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
            )
            matching.append(item)
            if item.rowModel.isPinned {
                pinned.append(item)
            } else {
                regular.append(item)
            }
        }
        // JHT_MOD_END CONVERSATION_LIST_RENDER_LOOP_PERF_20260912 - 修改结束
        let sortedPinned = sortedConversationItems(pinned)
        let sortedRegular = sortedConversationItems(regular)
        let sections = ConversationRenderSections(
            matching: matching,
            pinned: sortedPinned,
            regular: sortedRegular,
            // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：缓存完整可见顺序，减少列表渲染和签名比较时的数组分配
            ordered: sortedPinned + sortedRegular
            // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        )
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_RENDER_SECTIONS_RESULT - 修改开始：慢渲染缓存输出采样
        #if DEBUG
        ConversationListLagDiagnostics.logIfSlow(
            event: "render_sections",
            startedAt: renderStartedAt,
            thresholdMS: 16,
            details: "source_count=\(state.conversations.count) matching=\(matching.count) pinned=\(pinned.count) regular=\(regular.count) total_messages=\(ConversationListLagDiagnostics.totalMessages(in: state.conversations)) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
        )
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_RENDER_SECTIONS_RESULT - 修改结束
        return sections
    }

    private func conversationOrderIDs(_ sections: ConversationRenderSections) -> [String] {
        sections.ordered.map(\.id)
    }

    private func conversationRenderSignature(_ sections: ConversationRenderSections) -> [ConversationRenderSignature] {
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_SIGNATURE - 修改开始：检测签名构建耗时，定位列表更新比较成本
        #if DEBUG
        let signatureStartedAt = Date()
        #endif
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：用 Equatable 结构体签名替代字符串数组拼接，降低大列表缓存比较分配
        let signature = sections.ordered.map { item in
            let conversation = item.conversation
            return ConversationRenderSignature(
                rowModel: item.rowModel,
                title: conversation.title,
                subtitle: conversation.subtitle,
                memberCount: conversation.memberCount,
                avatarURL: conversation.avatarURL,
                avatarVersion: conversation.avatarVersion,
                avatarUpdatedAt: conversation.avatarUpdatedAt,
                lastMsgSeq: conversation.lastMsgSeq,
                lastReadSeq: conversation.lastReadSeq,
                hasMention: conversation.hasMention,
                mentionCount: conversation.mentionCount,
                mentionSummaryText: conversation.mentionSummaryText,
                mentionSummaryMessageID: conversation.mentionSummaryMessageID,
                mentionSummaryChannelSeq: conversation.mentionSummaryChannelSeq,
                unreadMention: item.unreadMention
            )
        }
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        #if DEBUG
        ConversationListLagDiagnostics.logIfSlow(
            event: "render_signature",
            startedAt: signatureStartedAt,
            thresholdMS: 12,
            details: "items=\(signature.count)"
        )
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_SIGNATURE - 修改结束
        return signature
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：生成轻量输入签名，命中时跳过完整 render_sections
    private func conversationRenderInputSignature() -> ConversationRenderInputSignature {
        ConversationRenderInputSignature(
            filter: filter,
            query: trimmedSearchQuery,
            currentUser: state.currentUser,
            currentIdentityIDs: state.currentUserIdentitySet().sorted(),
            conversations: state.conversations
        )
    }

    private func invalidateConversationRenderInputSignature() {
        cachedConversationRenderInputSignature = nil
    }
    // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束

    private func applyConversationOrderActivity(previousOrder: [String], nextOrder: [String], trackActivity: Bool) {
        let decision = conversationListActivityDecision(
            previousOrder: previousOrder,
            nextOrder: nextOrder,
            isNearTop: isNearConversationListTop,
            trackingEnabled: trackActivity && filter != "@我" && query.isEmpty
        )
        switch decision {
        case .none:
            break
        case .scrollToTop:
            conversationListTopScrollRequest += 1
        case .showHint:
            showConversationActivityHint = true
        }
    }

    private func rebuildConversationSectionsCache(trackActivity: Bool = false) {
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_REBUILD_CACHE - 修改开始：检测会话列表缓存重建总耗时和是否真实变更
        #if DEBUG
        let rebuildStartedAt = Date()
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_REBUILD_CACHE - 修改结束
        // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：输入未变化时直接复用已缓存分段
        let nextInputSignature = conversationRenderInputSignature()
        if cachedConversationRenderInputSignature == nextInputSignature {
            #if DEBUG
            ConversationListLagDiagnostics.logIfSlow(
                event: "rebuild_sections_skipped_unchanged_input",
                startedAt: rebuildStartedAt,
                thresholdMS: 0,
                details: "items=\(cachedConversationSections.ordered.count) source_count=\(state.conversations.count) total_messages=\(ConversationListLagDiagnostics.totalMessages(in: state.conversations)) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
            )
            #endif
            return
        }
        // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
        let previousOrder = conversationOrderIDs(cachedConversationSections)
        // JHT_MOD_BEGIN CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改开始：直接复用旧签名，减少大列表比较前的主线程重复计算
        let previousSignature = cachedConversationRenderSignature
        // JHT_MOD_END CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改结束
        let nextSections = filter == "@我" ? .empty : renderConversationSections()
        let nextOrder = conversationOrderIDs(nextSections)
        let nextSignature = conversationRenderSignature(nextSections)
        guard previousSignature != nextSignature else {
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：记录已验证过的输入签名，后续相同输入不再重复完整重建
            cachedConversationRenderInputSignature = nextInputSignature
            // JHT_MOD_BEGIN CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改开始：保持签名缓存与当前输入一致，便于后续直接比较
            cachedConversationRenderSignature = nextSignature
            // JHT_MOD_END CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改结束
            // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
            // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_REBUILD_NO_CHANGE - 修改开始：签名无变化但耗时过高时输出
            #if DEBUG
            ConversationListLagDiagnostics.logIfSlow(
                event: "rebuild_sections_no_change",
                startedAt: rebuildStartedAt,
                thresholdMS: 20,
                details: "items=\(nextOrder.count) total_messages=\(ConversationListLagDiagnostics.totalMessages(in: state.conversations)) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
            )
            #endif
            // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_REBUILD_NO_CHANGE - 修改结束
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cachedConversationSections = nextSections
        }
        // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：缓存最新有效输入签名
        cachedConversationRenderInputSignature = nextInputSignature
        // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
        // JHT_MOD_BEGIN CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改开始：同步缓存当前展示签名，避免下一轮重复生成旧签名
        cachedConversationRenderSignature = nextSignature
        // JHT_MOD_END CONVERSATION_LIST_SIGNATURE_CACHE_PERF_20260912 - 修改结束
        applyConversationOrderActivity(previousOrder: previousOrder, nextOrder: nextOrder, trackActivity: trackActivity)
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_REBUILD_CHANGED - 修改开始：签名变更时输出慢重建信息
        #if DEBUG
            ConversationListLagDiagnostics.logIfSlow(
                event: "rebuild_sections_changed",
                startedAt: rebuildStartedAt,
                thresholdMS: 20,
                details: "previous_items=\(previousOrder.count) next_items=\(nextOrder.count) total_messages=\(ConversationListLagDiagnostics.totalMessages(in: state.conversations)) track_activity=\(trackActivity) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
            )
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_REBUILD_CHANGED - 修改结束
    }

    private func rebuildMentionCache(includeRecords: Bool) {
        if includeRecords {
            cachedMentionRecords = renderMentionRecords()
        }
        cachedUnreadMentionCount = renderUnreadMentionCount()
    }

    private func rebuildAlertingUnreadCache() {
        cachedAlertingUnreadTotal = renderAlertingUnreadTotal()
    }

    private func rebuildAnnouncementCache() {
        cachedAnnouncementItems = renderAnnouncementItems()
    }

    private func rebuildConversationRenderCaches(trackActivity: Bool = false) {
        rebuildConversationSectionsCache(trackActivity: trackActivity)
        rebuildMentionCache(includeRecords: filter == "@我")
        rebuildAlertingUnreadCache()
    }

    private func scheduleConversationStoreChangeHandling() {
        // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：聊天页显示时延后会话列表 UI 缓存响应
        if selectedConversationRoute != nil {
            conversationStoreChangeCoalescer.cancelPending()
            markConversationRenderCacheDirtyWhileRouteActive(reason: "store_change")
            return
        }
        // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
        guard let token = conversationStoreChangeCoalescer.begin() else { return }
        // @Published 在 willSet 阶段发射；延后一轮，确保所有投影读取的是新快照。
        DispatchQueue.main.async {
            guard conversationStoreChangeCoalescer.finish(token) else { return }
            // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：排队期间进入聊天页时继续延后
            if selectedConversationRoute != nil {
                markConversationRenderCacheDirtyWhileRouteActive(reason: "store_change_after_delay")
                return
            }
            // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
            handleConversationStoreChange()
        }
    }

    private func handleConversationStoreChange() {
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_STORE_CHANGE - 修改开始：检测会话数据发布后列表侧处理耗时
        #if DEBUG
        let changeStartedAt = Date()
        defer {
            ConversationListLagDiagnostics.logIfSlow(
                event: "store_change_handled",
                startedAt: changeStartedAt,
                thresholdMS: 18,
                details: "source_count=\(state.conversations.count) cached_count=\(cachedConversationSections.matching.count) total_messages=\(ConversationListLagDiagnostics.totalMessages(in: state.conversations)) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
            )
        }
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_STORE_CHANGE - 修改结束
        rebuildAlertingUnreadCache()
        if filter == "未读" || filter == "@我" {
            conversationCacheRebuildTask?.cancel()
            conversationCacheRebuildTask = nil
            rebuildConversationRenderCaches(trackActivity: true)
        } else {
            scheduleConversationRenderCacheRebuild()
        }
    }

    private func scheduleConversationRenderCacheRebuild(now: Date = Date()) {
        // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：列表不可见时不启动延迟重建任务
        if selectedConversationRoute != nil {
            markConversationRenderCacheDirtyWhileRouteActive(reason: "render_cache_schedule")
            return
        }
        // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
        conversationCacheRebuildTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            listClockTick = now
        }
        conversationCacheRebuildTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：任务等待期间若进入聊天页，则留到返回后重建
            if selectedConversationRoute != nil {
                markConversationRenderCacheDirtyWhileRouteActive(reason: "route_active_after_delay")
                return
            }
            // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                listClockTick = Date()
            }
            rebuildConversationRenderCaches(trackActivity: true)
        }
    }

    private func rebuildVisibleConversationOrderCache(trackActivity: Bool = false) {
        if filter == "@我" {
            rebuildMentionCache(includeRecords: true)
        } else {
            rebuildConversationSectionsCache(trackActivity: trackActivity)
        }
    }

    // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：集中标记聊天页期间被延后的列表 UI 缓存重建
    private func markConversationRenderCacheDirtyWhileRouteActive(reason: String) {
        guard selectedConversationRoute != nil else { return }
        let shouldLog = !conversationRenderCacheDirtyWhileRouteActive
        conversationRenderCacheDirtyWhileRouteActive = true
        conversationCacheRebuildTask?.cancel()
        conversationCacheRebuildTask = nil
        #if DEBUG
        if shouldLog {
            print("[JHT Perf] conversation_list_lag event=defer_rebuild_route_active reason=\(reason) source_count=\(state.conversations.count) cached_count=\(cachedConversationSections.matching.count)")
        }
        #endif
    }
    // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束

    private func rebuildQueryDependentCaches() {
        rebuildConversationSectionsCache()
        rebuildMentionCache(includeRecords: filter == "@我")
    }

    private func rebuildAllRenderCaches() {
        rebuildConversationRenderCaches()
        rebuildAnnouncementCache()
    }

    private func latestUnreadMention(in conversation: Conversation) -> MentionPreview? {
        if conversation.hasMention, !conversation.mentionSummaryText.isEmpty {
            return MentionPreview(senderName: conversationDisplayTitle(for: conversation), text: conversation.mentionSummaryText)
        }
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：直接取最新未读 mention，避免为列表行预览构造临时数组
        return latestUnreadMentionMessage(in: conversation).map { message in
            MentionPreview(senderName: mentionSenderDisplayName(for: message), text: message.text)
        }
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    }

    private func earliestUnreadMentionJumpTarget(in conversation: Conversation) -> RemoteTenantSearchJumpTarget? {
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：点击跳转直接查找最早未读 mention，避免生成数组
        if let message = firstUnreadMentionMessage(in: conversation) {
            return RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: conversation.id,
                channelType: mentionJumpChannelType(conversation.kind),
                channelSeq: message.channelSeq > 0 ? message.channelSeq : nil,
                messageID: message.id.isEmpty ? nil : message.id
            )
        }
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        guard conversation.hasMention,
              !conversation.mentionSummaryText.isEmpty,
              (!conversation.mentionSummaryMessageID.isEmpty || conversation.mentionSummaryChannelSeq > 0) else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: conversation.id,
            channelType: mentionJumpChannelType(conversation.kind),
            channelSeq: conversation.mentionSummaryChannelSeq > 0 ? conversation.mentionSummaryChannelSeq : nil,
            messageID: conversation.mentionSummaryMessageID.isEmpty ? nil : conversation.mentionSummaryMessageID
        )
    }

    private func mentionSenderDisplayName(for message: ChatMessage) -> String {
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [storedName],
            fallback: storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
        )
    }

    private func unreadMentionMessages(in conversation: Conversation) -> [ChatMessage] {
        if conversation.lastReadSeq > 0 {
            return conversation.messages.filter { message in
                message.channelSeq > conversation.lastReadSeq && isMentionMessage(message)
            }
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return [] }
        return conversation.messages
            .suffix(unreadCount)
            .filter { isMentionMessage($0) }
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：未读 mention 扫描复用，保持原筛选语义但减少数组分配
    private func firstUnreadMentionMessage(in conversation: Conversation) -> ChatMessage? {
        if conversation.lastReadSeq > 0 {
            for message in conversation.messages where message.channelSeq > conversation.lastReadSeq && isMentionMessage(message) {
                return message
            }
            return nil
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return nil }
        for message in conversation.messages.suffix(unreadCount) where isMentionMessage(message) {
            return message
        }
        return nil
    }

    private func latestUnreadMentionMessage(in conversation: Conversation) -> ChatMessage? {
        if conversation.lastReadSeq > 0 {
            for message in conversation.messages.reversed() where message.channelSeq > conversation.lastReadSeq && isMentionMessage(message) {
                return message
            }
            return nil
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return nil }
        for message in conversation.messages.suffix(unreadCount).reversed() where isMentionMessage(message) {
            return message
        }
        return nil
    }

    private func unreadMentionMessageCount(in conversation: Conversation) -> Int {
        if conversation.lastReadSeq > 0 {
            var count = 0
            for message in conversation.messages where message.channelSeq > conversation.lastReadSeq && isMentionMessage(message) {
                count += 1
            }
            return count
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return 0 }
        var count = 0
        for message in conversation.messages.suffix(unreadCount) where isMentionMessage(message) {
            count += 1
        }
        return count
    }
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

}

private struct TenantGlobalSearchResultsView: View {
    let query: String
    let response: RemoteTenantSearchResponse?
    let excludedResultIDs: Set<String>
    let invalidations: [SearchInvalidationEvent]
    let isLoading: Bool
    let isLoadingMore: Bool
    let selectedType: String?
    let onSelectType: (String?) -> Void
    let onRemoveFilter: (RemoteTenantSearchParsedFilter) -> Void
    let onLoadMore: (String) -> Void
    let onSelect: (RemoteTenantSearchResult) -> Void

    private let sections: [(type: String, title: String, icon: String)] = [
        ("contacts", "联系人", "person.crop.circle"),
        ("groups", "群聊", "person.3.fill"),
        ("conversations", "会话", "bubble.left.and.bubble.right.fill"),
        ("messages", "聊天记录", "text.bubble.fill"),
        ("files", "文件", "doc.fill")
    ]

    private var displayedSections: [(type: String, title: String, icon: String)] {
        guard let selectedType else { return sections }
        return sections.filter { $0.type == selectedType }
    }

    private var hasResults: Bool {
        displayedSections.contains { section in
            filteredItems(for: section.type).isEmpty == false
        }
    }

    private func filteredItems(for type: String) -> [RemoteTenantSearchResult] {
        response?.resultsByType[type]?.items.filter { item in
            !excludedResultIDs.contains(item.id)
                && !invalidations.contains(where: { item.matchesSearchInvalidation($0) })
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TenantGlobalSearchTypeTabs(
                sections: sections,
                selectedType: selectedType,
                response: response,
                filteredCount: { filteredItems(for: $0).count },
                onSelect: onSelectType
            )

            if let response, !response.parsedFilters.isEmpty {
                TenantSearchParsedFilterChips(filters: response.parsedFilters, onRemove: onRemoveFilter)
            }

            if isLoading && response == nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(IMColor.brand)
                    Text("正在搜索")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.92)))
            } else if let response, hasResults {
                ForEach(displayedSections, id: \.type) { section in
                    if let bucket = response.resultsByType[section.type] {
                        let items = filteredItems(for: section.type)
                        if !items.isEmpty {
                            TenantGlobalSearchSection(
                                type: section.type,
                                title: section.title,
                                icon: section.icon,
                                count: bucket.count,
                                hasMore: bucket.hasMore,
                                isLoadingMore: isLoadingMore && selectedType == section.type,
                                showsLoadMore: selectedType == section.type,
                                items: items,
                                onLoadMore: onLoadMore,
                                onSelect: onSelect
                            )
                        }
                    }
                }
            } else if selectedType != nil && !query.isEmpty && !isLoading {
                EmptyStateView(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "当前分类无结果",
                    subtitle: "清除分类或调整筛选条件后再试。"
                )
            } else if !query.isEmpty && !isLoading {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "没有搜索结果",
                    subtitle: "换个关键词试试，或检查联系人、群聊、消息和文件名称。"
                )
            }
        }
        .accessibilityIdentifier("tenant_global_search_results")
    }
}

private struct TenantGlobalSearchTypeTabs: View {
    let sections: [(type: String, title: String, icon: String)]
    let selectedType: String?
    let response: RemoteTenantSearchResponse?
    let filteredCount: (String) -> Int
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                TenantSearchTypeChip(
                    title: "全部",
                    count: totalCount,
                    isSelected: selectedType == nil
                ) {
                    onSelect(nil)
                }
                ForEach(sections, id: \.type) { section in
                    TenantSearchTypeChip(
                        title: section.title,
                        count: count(for: section.type),
                        isSelected: selectedType == section.type
                    ) {
                        onSelect(section.type)
                    }
                }
            }
        }
    }

    private var totalCount: Int? {
        guard let response else { return nil }
        let total = sections.reduce(0) { $0 + (response.resultsByType[$1.type]?.count ?? filteredCount($1.type)) }
        return total > 0 ? total : nil
    }

    private func count(for type: String) -> Int? {
        guard let response else { return nil }
        let count = response.resultsByType[type]?.count ?? filteredCount(type)
        return count > 0 ? count : nil
    }
}

private struct TenantSearchTypeChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .black))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : IMColor.brand)
                }
            }
            .foregroundStyle(isSelected ? .white : IMColor.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(isSelected ? IMColor.brand : .white.opacity(0.96)))
        }
        .buttonStyle(.plain)
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

private func visibleTenantSearchItems(_ items: [RemoteTenantSearchResult]) -> [RemoteTenantSearchResult] {
    items.filter { !$0.isBlockedFromChatSearchDisplay }
}

private struct TenantGlobalSearchSection: View {
    let type: String
    let title: String
    let icon: String
    let count: Int
    let hasMore: Bool
    let isLoadingMore: Bool
    let showsLoadMore: Bool
    let items: [RemoteTenantSearchResult]
    let onLoadMore: (String) -> Void
    let onSelect: (RemoteTenantSearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(IMColor.brand.opacity(0.10)))
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                if count > items.count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(visibleTenantSearchItems(items), id: \.id) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        TenantSearchResultRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tenant_search_result_\(item.type)_\(item.resultID)")
                    if item.id != items.last?.id {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
                if showsLoadMore && hasMore {
                    Divider()
                        .padding(.leading, 48)
                    Button {
                        onLoadMore(type)
                    } label: {
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
                        .frame(height: 42)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingMore)
                }
            }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.94)))
        }
    }
}

private struct TenantSearchResultRow: View {
    @EnvironmentObject private var state: AppState

    let item: RemoteTenantSearchResult
    private var displayModel: TenantSearchResultDisplayModel {
        item.displayModel
    }

    private var contactDisplayName: String? {
        guard let exactUID,
              let contact = state.contacts.first(where: {
                  [$0.id, $0.userID, $0.username]
                      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                      .contains(exactUID)
              }) else {
            return nil
        }
        return state.remarkPreferredDisplayName(for: contact)
    }

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
                        text: contactDisplayName ?? displayModel.primaryText,
                        ranges: item.highlightRanges,
                        field: contactDisplayName == nil ? displayModel.primaryField : "viewer_private_remark",
                        font: .system(size: 14, weight: .black),
                        color: IMColor.ink
                    )
                    if let exactUID {
                        CertificationPillView(
                            exactUID: exactUID,
                            compact: true
                        )
                    }
                }
                if let detailText = displayModel.secondaryText {
                    TenantSearchHighlightedText(
                        text: detailText,
                        ranges: item.highlightRanges,
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

    private var exactUID: String? {
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

private struct TenantSearchHighlightedText: View {
    let text: String
    let ranges: [RemoteTenantSearchHighlightRange]
    let field: String
    let font: Font
    let color: Color

    var body: some View {
        highlightedText
            .font(font)
            .lineLimit(1)
    }

    private var highlightedText: Text {
        let filteredRanges = ranges
            .filter { $0.field == field && $0.length > 0 }
            .sorted { $0.start < $1.start }
        guard !filteredRanges.isEmpty else {
            return Text(text).foregroundColor(color)
        }
        let characters = Array(text)
        var cursor = 0
        var rendered = Text("")
        for range in filteredRanges {
            let start = min(max(range.start, 0), characters.count)
            let end = min(max(start + range.length, start), characters.count)
            guard end > start else { continue }
            if start > cursor {
                rendered = rendered + Text(String(characters[cursor..<start])).foregroundColor(color)
            }
            rendered = rendered + Text(String(characters[start..<end])).foregroundColor(IMColor.brand)
            cursor = max(cursor, end)
        }
        if cursor < characters.count {
            rendered = rendered + Text(String(characters[cursor..<characters.count])).foregroundColor(color)
        }
        return rendered
    }
}

private struct ConversationRenderItem: Identifiable {
    let conversation: Conversation
    let displayTitle: String
    let unreadMention: MentionPreview?
    let sortScore: Double
    // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_MODEL - 修改开始：会话列表行轻量展示缓存
    let rowPresentation: ConversationRowPresentation
    // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRESENTATION_MODEL - 修改结束：会话列表行轻量展示缓存
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：行视图只消费可见字段，降低 SwiftUI diff 和渲染压力
    let rowModel: ConversationRowModel
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

    var id: String { rowModel.id }
}

// JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_STRUCT - 修改开始：抽离列表行展示所需字段，避免滑动时重复查询 AppState
private struct ConversationRowPresentation: Equatable {
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let avatarImageCacheKey: String
    let directCertificationUID: String
    let directCertificationPresentation: CertificationPresentation?
}
// JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRESENTATION_STRUCT - 修改结束：抽离列表行展示所需字段，避免滑动时重复查询 AppState

// JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：会话列表行轻量展示模型，避免把 Conversation.messages 带入 SwiftUI 行渲染树
private struct ConversationRowModel: Equatable, Identifiable {
    let id: String
    let kind: ConversationKind
    let displayTitle: String
    let lastMessage: String
    let time: String
    let unread: Int
    let isPinned: Bool
    let isMuted: Bool
    let accentHex: UInt
    let hasUnreadReaction: Bool
    let unreadReactionCount: Int
    let sortTimestamp: TimeInterval
    let rowPresentation: ConversationRowPresentation
}

// JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：会话列表渲染输入签名，仅用于跳过无变化重建
private struct ConversationRenderInputSignature: Equatable {
    let filter: String
    let query: String
    let currentUserID: String
    let currentUserUserID: String
    let currentUserUsername: String
    let currentUserName: String
    let currentIdentityIDs: [String]
    let conversations: [ConversationRenderConversationInputSignature]

    init(filter: String, query: String, currentUser: IMUser, currentIdentityIDs: [String], conversations: [Conversation]) {
        self.filter = filter
        self.query = query
        currentUserID = currentUser.id
        currentUserUserID = currentUser.userID
        currentUserUsername = currentUser.username
        currentUserName = currentUser.name
        self.currentIdentityIDs = currentIdentityIDs
        self.conversations = conversations.map(ConversationRenderConversationInputSignature.init)
    }
}

private struct ConversationRenderConversationInputSignature: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: ConversationKind
    let lastMessage: String
    let time: String
    let unread: Int
    let isPinned: Bool
    let isMuted: Bool
    let memberCount: Int?
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let hasUnreadReaction: Bool
    let unreadReactionCount: Int
    let lastMsgSeq: Int64
    let lastReadSeq: Int64
    let hasMention: Bool
    let mentionCount: Int
    let mentionSummaryText: String
    let mentionSummaryMessageID: String
    let mentionSummaryChannelSeq: Int64
    let sortTimestamp: TimeInterval
    let participants: [ConversationRenderUserInputSignature]
    let latestIncomingPeerMessage: ConversationRenderPeerMessageInputSignature?
    let unreadMentionCandidateMessages: [ConversationRenderMessageInputSignature]

    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        subtitle = conversation.subtitle
        kind = conversation.kind
        self.lastMessage = conversation.lastMessage
        time = conversation.time
        unread = conversation.unread
        isPinned = conversation.isPinned
        isMuted = conversation.isMuted
        memberCount = conversation.memberCount
        avatarURL = conversation.avatarURL
        avatarVersion = conversation.avatarVersion
        avatarUpdatedAt = conversation.avatarUpdatedAt
        hasUnreadReaction = conversation.hasUnreadReaction
        unreadReactionCount = conversation.unreadReactionCount
        lastMsgSeq = conversation.lastMsgSeq
        lastReadSeq = conversation.lastReadSeq
        hasMention = conversation.hasMention
        mentionCount = conversation.mentionCount
        mentionSummaryText = conversation.mentionSummaryText
        mentionSummaryMessageID = conversation.mentionSummaryMessageID
        mentionSummaryChannelSeq = conversation.mentionSummaryChannelSeq
        sortTimestamp = conversation.sortTimestamp
        participants = conversation.participants.map(ConversationRenderUserInputSignature.init)
        if conversation.kind == .direct {
            latestIncomingPeerMessage = conversation.messages
                .reversed()
                .first { !$0.isOutgoing }
                .map(ConversationRenderPeerMessageInputSignature.init)
        } else {
            latestIncomingPeerMessage = nil
        }
        if conversation.mentionSummaryText.isEmpty {
            if conversation.lastReadSeq > 0 {
                unreadMentionCandidateMessages = conversation.messages
                    .filter { $0.channelSeq > conversation.lastReadSeq }
                    .map(ConversationRenderMessageInputSignature.init)
            } else {
                let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
                unreadMentionCandidateMessages = unreadCount > 0
                    ? conversation.messages.suffix(unreadCount).map(ConversationRenderMessageInputSignature.init)
                    : []
            }
        } else {
            unreadMentionCandidateMessages = []
        }
    }
}

private struct ConversationRenderUserInputSignature: Equatable {
    let id: String
    let userID: String
    let username: String
    let name: String
    let status: String
    let avatarSeed: UInt
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String

    init(_ user: IMUser) {
        id = user.id
        userID = user.userID
        username = user.username
        name = user.name
        status = user.status
        avatarSeed = user.avatarSeed
        avatarURL = user.avatarURL
        avatarVersion = user.avatarVersion
        avatarUpdatedAt = user.avatarUpdatedAt
    }
}

private struct ConversationRenderPeerMessageInputSignature: Equatable {
    let senderId: String
    let senderName: String
    let senderAvatarURL: String
    let senderAvatarVersion: String
    let senderAvatarUpdatedAt: String
    let senderAvatarSeed: UInt

    init(_ message: ChatMessage) {
        senderId = message.senderId
        senderName = message.senderName
        senderAvatarURL = message.senderAvatarURL
        senderAvatarVersion = message.senderAvatarVersion
        senderAvatarUpdatedAt = message.senderAvatarUpdatedAt
        senderAvatarSeed = message.senderAvatarSeed
    }
}

private struct ConversationRenderMessageInputSignature: Equatable {
    let id: String
    let senderId: String
    let senderName: String
    let text: String
    let channelSeq: Int64
    let isOutgoing: Bool
    let status: MessageDelivery
    let kind: MessageKind
    let isDeletedLocally: Bool
    let mentionExcluded: Bool
    let mentionAll: Bool
    let mentionedUsers: [MentionIdentity]

    init(_ message: ChatMessage) {
        id = message.id
        senderId = message.senderId
        senderName = message.senderName
        text = message.text
        channelSeq = message.channelSeq
        isOutgoing = message.isOutgoing
        status = message.status
        kind = message.kind
        isDeletedLocally = message.isDeletedLocally
        mentionExcluded = message.mentionExcluded
        mentionAll = message.mentionAll
        mentionedUsers = message.mentionedUsers
    }
}
// JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束

private struct ConversationRenderSignature: Equatable {
    let rowModel: ConversationRowModel
    let title: String
    let subtitle: String
    let memberCount: Int?
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let lastMsgSeq: Int64
    let lastReadSeq: Int64
    let hasMention: Bool
    let mentionCount: Int
    let mentionSummaryText: String
    let mentionSummaryMessageID: String
    let mentionSummaryChannelSeq: Int64
    let unreadMention: MentionPreview?
}
// JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

private struct ConversationRenderSections {
    let matching: [ConversationRenderItem]
    let pinned: [ConversationRenderItem]
    let regular: [ConversationRenderItem]
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：缓存已排序可见列表，避免渲染期间重复拼接
    let ordered: [ConversationRenderItem]
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束

    static let empty = ConversationRenderSections(matching: [], pinned: [], regular: [], ordered: [])
}

private struct ConversationListTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MentionMessageRecord: Identifiable {
    let id: String
    let conversationID: String
    let conversationTitle: String
    let conversationKind: ConversationKind
    let messageID: String
    let channelSeq: Int64
    let senderUID: String
    let senderName: String
    let senderSeed: UInt
    let senderAvatarURL: String
    let senderAvatarVersion: String
    let senderAvatarUpdatedAt: String
    let text: String
    let time: String
    let isUnread: Bool
    let unreadCount: Int
    let sortScore: Int
}

struct MentionPreview: Equatable {
    let senderName: String
    let text: String
}

private struct MentionMessageList: View {
    @EnvironmentObject private var state: AppState

    let records: [MentionMessageRecord]
    let mentionTarget: String
    var openRecord: (MentionMessageRecord) -> Void

    var body: some View {
        if records.isEmpty {
            EmptyStateView(symbol: "at", title: "暂无 @ 我的消息", subtitle: "群聊里有人提到你时，会按最新时间展示在这里。")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("@ 我的消息")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Spacer()
                    Text("新消息在上方")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .padding(.horizontal, 2)

                ForEach(records) { record in
                    Button {
                        openRecord(record)
                    } label: {
                        MentionMessageRow(record: record, mentionTarget: mentionTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mention_message_row_\(record.id)")
                    .accessibilityLabel(
                        [
                            "@我消息 \(record.senderName)",
                            state.certificationPresentation(
                                forExactUID: record.senderUID
                            )?.accessibilityLabel
                        ]
                        .compactMap { $0 }
                        .joined(separator: "，")
                    )
                }
            }
        }
    }
}

private struct MentionMessageRow: View {
    @EnvironmentObject private var state: AppState

    let record: MentionMessageRecord
    let mentionTarget: String

    private var conversationTag: (title: String, color: Color)? {
        switch record.conversationKind {
        case .group:
            return ("群", IMColor.warning)
        case .system:
            return ("系", IMColor.cyan)
        case .direct:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AvatarView(name: record.senderName, seed: record.senderSeed, size: 44, imageURL: record.senderAvatarURL, avatarVersion: record.senderAvatarVersion, avatarUpdatedAt: record.senderAvatarUpdatedAt, certification: state.certificationPresentation(forExactUID: record.senderUID))
                if let conversationTag {
                    ConversationTypeBadge(title: conversationTag.title, color: conversationTag.color)
                        .offset(x: 2, y: -3)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(record.senderName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: record.senderUID,
                        compact: true
                    )
                    if record.isUnread, let unreadText = UnreadBadgeFormatter.text(record.unreadCount) {
                        Text(unreadText)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(IMColor.danger))
                            .accessibilityLabel("未读 \(unreadText) 条")
                    }
                    Spacer(minLength: 6)
                    Text(record.time)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }

                mentionSnippetText
                    .font(.system(size: 14, weight: .semibold))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Text(record.conversationTitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted.opacity(0.55))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(IMColor.brand.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var mentionSnippetText: Text {
        if record.isUnread {
            return highlightedMentionText(record.text, target: mentionTarget, baseColor: IMColor.ink)
        }
        return Text(record.text).foregroundColor(IMColor.muted)
    }
}

private struct ConversationTypeBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(title == "群" ? IMColor.warning : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(title == "群" ? Color(hex: 0xFFF4D6) : color)
                    .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.4))
            )
            .shadow(color: color.opacity(0.18), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

private struct SystemConversationAvatar: View {
    let size: CGFloat
    var imageURL: String = ""

    var body: some View {
        SystemNoticeLogoAvatar(size: size)
    }
}

private struct ConversationInteractiveRow: View, Equatable {
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：交互行只持有轻量展示字段，避免完整 Conversation 参与 SwiftUI diff
    let rowModel: ConversationRowModel
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    let mentionTarget: String
    let unreadMention: MentionPreview?
    let systemNoticeAvatarURL: String
    var onTap: () -> Void
    var onLongPress: () -> Void

    nonisolated static func == (lhs: ConversationInteractiveRow, rhs: ConversationInteractiveRow) -> Bool {
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：直接比较轻量行模型，避开 Conversation.messages 等大字段
        lhs.rowModel == rhs.rowModel
            && lhs.mentionTarget == rhs.mentionTarget
            && lhs.unreadMention == rhs.unreadMention
            && lhs.systemNoticeAvatarURL == rhs.systemNoticeAvatarURL
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    }

    var body: some View {
        ConversationRow(
            rowModel: rowModel,
            mentionTarget: mentionTarget,
            unreadMention: unreadMention,
            systemNoticeAvatarURL: systemNoticeAvatarURL
        )
        // Renew the visual subtree on pin changes without changing the list row ID.
        // Reordering alone must not retain the previous unpinned presentation.
        .id(rowModel.isPinned)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onLongPress()
        }
        .accessibilityIdentifier("conversation_row_\(rowModel.id)")
        .accessibilityLabel(
            [
                "会话 \(rowModel.displayTitle)",
                rowModel.kind == .direct
                    ? rowModel.rowPresentation.directCertificationPresentation?.accessibilityLabel
                    : nil
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

private struct ConversationActionSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false
    let conversationID: String

    private var conversation: Conversation {
        state.conversation(id: conversationID)
    }

    private var unreadBadgeColor: Color {
        conversation.isMuted ? IMColor.muted.opacity(0.62) : IMColor.danger
    }

    private var directPeer: IMUser? {
        guard conversation.kind == .direct else { return nil }
        return state.directConversationProfilePeer(for: conversation)
    }

    private var directCertificationUID: String {
        guard conversation.kind == .direct else { return "" }
        return state.directConversationCertificationUID(for: conversation) ?? directPeer?.id ?? ""
    }

    private var avatarURL: String {
        conversation.kind == .direct ? directPeer?.displayAvatarURL ?? "" : conversation.avatarURL
    }

    private var avatarVersion: String {
        conversation.kind == .direct ? directPeer?.avatarVersion ?? "" : conversation.avatarVersion
    }

    private var avatarUpdatedAt: String {
        conversation.kind == .direct ? directPeer?.avatarUpdatedAt ?? "" : conversation.avatarUpdatedAt
    }

    private var displayTitle: String {
        if conversation.kind == .direct, let participant = directPeer {
            return state.remarkPreferredDisplayName(for: participant)
        }
        return conversation.title
    }

    @ViewBuilder
    private var avatar: some View {
        if conversation.kind == .system {
            SystemConversationAvatar(size: 46, imageURL: state.systemNoticeAvatarURL)
        } else if conversation.kind == .group {
            GroupAvatarView(name: displayTitle, seed: conversation.accentHex, size: 46, imageURL: avatarURL, avatarVersion: avatarVersion, avatarUpdatedAt: avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(for: conversation))
        } else {
            AvatarView(name: displayTitle, seed: conversation.accentHex, size: 46, imageURL: avatarURL, avatarVersion: avatarVersion, avatarUpdatedAt: avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: directCertificationUID))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(IMColor.line)
                .frame(width: 42, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayTitle)
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        if conversation.kind == .direct {
                            CertificationPillView(
                                exactUID: directCertificationUID,
                                compact: true
                            )
                        }
                    }
                    Text(conversation.lastMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(IMColor.line.opacity(0.78)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation_action_close")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Divider()
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ConversationActionRow(
                    symbol: conversation.isPinned ? "pin.slash.fill" : "pin.fill",
                    title: conversation.isPinned ? "取消置顶" : "置顶会话",
                    subtitle: conversation.isPinned ? "从置顶会话中移除" : "固定在会话列表顶部",
                    tint: IMColor.warning,
                    identifier: conversation.isPinned ? "conversation_action_unpin" : "conversation_action_pin"
                ) {
                    state.togglePinned(conversationID)
                    dismiss()
                }
                Divider().padding(.leading, 64)

                ConversationActionRow(
                    symbol: conversation.isMuted ? "bell.fill" : "bell.slash.fill",
                    title: conversation.isMuted ? "关闭免打扰" : "开启免打扰",
                    subtitle: conversation.isMuted ? "恢复新消息提醒" : "静默接收此会话消息",
                    tint: IMColor.brand,
                    identifier: conversation.isMuted ? "conversation_action_unmute" : "conversation_action_mute"
                ) {
                    state.toggleMuted(conversationID)
                    dismiss()
                }
                Divider().padding(.leading, 64)

                ConversationActionRow(
                    symbol: "trash.fill",
                    title: "删除会话",
                    subtitle: "仅删除本机列表记录",
                    tint: IMColor.danger,
                    isDestructive: true,
                    identifier: "conversation_action_delete"
                ) {
                    showDeleteAlert = true
                }
            }
        }
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.86), lineWidth: 1)
                )
                .shadow(color: Color(hex: 0x172033, alpha: 0.18), radius: 26, y: 14)
        )
        .padding(.horizontal, 14)
        .alert("删除会话？", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                state.deleteConversation(conversationID)
                dismiss()
            }
        } message: {
            Text("删除后仅移除本机会话列表记录，不会清空服务端消息。")
        }
    }
}

private struct ConversationActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    var isDestructive = false
    let identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(tint.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(isDestructive ? IMColor.danger : IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

private struct ConversationTopCard: View {
    @EnvironmentObject private var state: AppState
    let enterprise: Enterprise
    var openEnterprise: () -> Void
    var openConversation: (String) -> Void

    var body: some View {
        EnterpriseHeaderCard(
            enterprise: enterprise,
            isSwitchingEnabled: state.canOpenEnterpriseSwitcher(for: enterprise),
            action: openEnterprise
        ) {
            QuickAddMenu(openConversation: openConversation)
        }
    }
}

struct EnterpriseHeaderCard<Trailing: View>: View {
    let enterprise: Enterprise
    var isSwitchingEnabled = true
    var action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 13) {
            EnterpriseLogoView(
                enterprise: enterprise,
                size: 58,
                cornerRadius: 20,
                cacheKey: enterprise.logoImageCacheKey(scope: "enterprise-header")
            )

            if isSwitchingEnabled {
                Button(action: action) {
                    enterpriseContent
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("enterprise_switcher_entry")
                .accessibilityLabel("切换企业 \(enterprise.name)")
            } else {
                enterpriseContent
                    .accessibilityIdentifier("enterprise_current_entry")
                    .accessibilityLabel("当前企业 \(enterprise.name)")
            }

            trailing()
        }
        .glassCard(radius: 26)
    }

    private var enterpriseContent: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(enterprise.name)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                if !enterprise.displayCode.isEmpty {
                    Text("企业码 \(enterprise.displayCode)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                if !enterprise.isWorkspaceEnterable, !enterprise.workspaceDisabledDescription.isEmpty {
                    Label(enterprise.workspaceDisabledDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isSwitchingEnabled {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

enum QuickAddFlow: String, Equatable {
    case actions
    case directChat
    case findUser
    case createGroup
}

struct QuickAddPresentationState: Equatable {
    var isPresented = false
    var flow: QuickAddFlow = .actions

    mutating func presentActions() {
        flow = .actions
        isPresented = true
    }

    mutating func select(_ nextFlow: QuickAddFlow) {
        flow = nextFlow
        isPresented = true
    }

    mutating func dismiss() {
        isPresented = false
        flow = .actions
    }
}

private struct QuickAddMenu: View {
    @EnvironmentObject private var state: AppState
    var openConversation: (String) -> Void
    @State private var presentation = QuickAddPresentationState()

    var body: some View {
        Button {
            presentation.presentActions()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(IMColor.brand)
                .frame(width: 44, height: 44)
                .background(Circle().fill(IMColor.brand.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation_plus_button")
        .accessibilityLabel("会话新增")
        .sheet(isPresented: $presentation.isPresented, onDismiss: {
            presentation.dismiss()
        }) {
            QuickAddSheetHost(
                flow: $presentation.flow,
                canCreateGroup: state.canCreateGroupChat,
                select: { presentation.select($0) },
                close: { presentation.dismiss() },
                openConversation: { conversationID in
                    presentation.dismiss()
                    openConversation(conversationID)
                }
            )
            .environmentObject(state)
        }
    }
}

private struct QuickAddSheetHost: View {
    @Binding var flow: QuickAddFlow
    let canCreateGroup: Bool
    let select: (QuickAddFlow) -> Void
    let close: () -> Void
    let openConversation: (String) -> Void

    @ViewBuilder
    var body: some View {
        switch flow {
        case .actions:
            QuickAddActionSheet(
                canCreateGroup: canCreateGroup,
                onClose: close,
                onDirectChat: { select(.directChat) },
                onFindUser: { select(.findUser) },
                onCreateGroup: { select(.createGroup) }
            )
            .presentationDetentsCompat([.height(canCreateGroup ? 320 : 260)])
            .presentationDragIndicatorCompat(.hidden)
            .presentationCornerRadiusCompat(30)
            .presentationBackgroundUltraThinMaterialCompat()
        case .directChat:
            StartDirectChatSheet(openConversation: openConversation)
                .presentationDetentsCompat([.medium, .large])
                .presentationCornerRadiusCompat(30)
        case .createGroup:
            CreateGroupSheet(openConversation: openConversation)
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(30)
        case .findUser:
            FindUserSheet()
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(30)
        }
    }
}

private struct QuickAddActionSheet: View {
    let canCreateGroup: Bool
    let onClose: () -> Void
    let onDirectChat: () -> Void
    let onFindUser: () -> Void
    let onCreateGroup: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(IMColor.muted.opacity(0.32))
                .frame(width: 42, height: 5)
                .padding(.top, 8)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("新增")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("选择要发起的真实会话流程")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.86)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("quick_add_close_button")
            }
            .padding(.horizontal, 2)

            VStack(spacing: 10) {
                QuickAddActionRow(symbol: "person.badge.plus", title: "发起单聊", subtitle: "选择当前企业好友，进入单聊会话", identifier: "quick_add_direct_chat", action: onDirectChat)
                QuickAddActionRow(symbol: "person.text.rectangle.fill", title: "查找用户", subtitle: "通过用户 ID 搜索同企业用户并申请好友", identifier: "quick_add_find_user", action: onFindUser)
                if canCreateGroup {
                    QuickAddActionRow(symbol: "person.3.fill", title: "创建群聊", subtitle: "输入群名并调用服务端建群接口", identifier: "quick_add_create_group", action: onCreateGroup)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}

private struct QuickAddActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(IMColor.brand.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.58))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.78), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

struct CreateGroupSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var isSubmitting = false
    var openConversation: (String) -> Void

    private var candidates: [IMUser] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = state.contacts
            .filter { $0.id != state.currentUser.id }
            .sorted {
                state.remarkPreferredDisplayName(for: $0)
                    .localizedCaseInsensitiveCompare(state.remarkPreferredDisplayName(for: $1)) == .orderedAscending
            }
        guard !keyword.isEmpty else { return source }
        return source.filter { user in
            IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: keyword
            )
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 14) {
                    quickSheetHeader(symbol: "person.3.sequence.fill", title: "创建群聊", subtitle: "群名必填，可直接拉入好友。普通用户无建群入口。")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("群名称")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                        TextField("输入群名称", text: $groupName)
                            .font(.system(size: 16, weight: .bold))
                            .keyboardType(.default)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(true)
                            .imReadableInputText()
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.92)))
                            .accessibilityIdentifier("create_group_name_input")
                    }
                    .plainCard(radius: 22)

                    SearchField(text: $query, placeholder: "搜索好友、用户ID或拼音")
                        .accessibilityIdentifier("create_group_member_search")

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            if candidates.isEmpty {
                                EmptyStateView(symbol: "person.2.slash.fill", title: "暂无可拉入好友", subtitle: "当前企业没有匹配的好友。")
                            } else {
                                ForEach(candidates) { user in
                                    selectableUserRow(user)
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    PrimaryButton(
                        title: isSubmitting ? "创建中..." : (selectedIDs.isEmpty ? "创建群聊" : "创建并拉入 \(selectedIDs.count) 人"),
                        systemImage: isSubmitting ? "hourglass" : "checkmark",
                        disabled: isSubmitting || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        submit()
                    }
                    .accessibilityIdentifier("create_group_submit_button")
                }
                .padding(18)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColor.brand)
                }
            }
        }
    }

    private func selectableUserRow(_ user: IMUser) -> some View {
        let displayName = state.remarkPreferredDisplayName(for: user)
        return Button {
            if selectedIDs.contains(user.id) {
                selectedIDs.remove(user.id)
            } else {
                selectedIDs.insert(user.id)
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.avatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: user.id,
                            compact: true
                        )
                    }
                    CopyableUserIDText(
                        value: user.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.id : user.userID,
                        prefix: "用户ID：",
                        font: .system(size: 12, weight: .semibold),
                        color: IMColor.muted
                    )
                }
                Spacer()
                Image(systemName: selectedIDs.contains(user.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(selectedIDs.contains(user.id) ? IMColor.brand : IMColor.muted.opacity(0.55))
            }
            .plainCard(radius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("create_group_member_row_\(user.id)")
        .accessibilityLabel(
            [
                "选择成员 \(displayName)",
                state.certificationPresentation(
                    forExactUID: user.id
                )?.accessibilityLabel
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let conversationID = await state.createGroup(name: groupName, memberIDs: Array(selectedIDs))
            isSubmitting = false
            if let conversationID {
                dismiss()
                openConversation(conversationID)
            }
        }
    }

    private func quickSheetHeader(symbol: String, title: String, subtitle: String) -> some View {
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
                dismiss()
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
        .plainCard(radius: 24)
    }
}

private struct StartDirectChatSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var openConversation: (String) -> Void

    private var contacts: [IMUser] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = state.contacts.sorted {
            state.remarkPreferredDisplayName(for: $0)
                .localizedCaseInsensitiveCompare(state.remarkPreferredDisplayName(for: $1)) == .orderedAscending
        }
        guard !keyword.isEmpty else { return source }
        return source.filter { user in
            IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: keyword
            )
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 14) {
                    quickSheetHeader(
                        symbol: "person.badge.plus",
                        title: "发起单聊",
                        subtitle: "联系人来自当前企业好友接口，选择联系人后进入聊天。"
                    )

                    SearchField(text: $query, placeholder: "搜索姓名、用户ID或拼音")
                        .accessibilityIdentifier("start_direct_chat_search_field")

                    if contacts.isEmpty {
                        EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有联系人", subtitle: "当前企业没有匹配的好友数据。")
                            .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(contacts) { user in
                                    directContactRow(user)
                                }
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
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.brand)
                }
            }
        }
    }

    private func directContactRow(_ user: IMUser) -> some View {
        let existingConversationID = state.directConversationID(for: user)
        let displayName = state.remarkPreferredDisplayName(for: user)
        return Button {
            guard let conversationID = state.openOrCreateDirectConversationID(for: user, activateChatsTab: false) else { return }
            dismiss()
            openConversation(conversationID)
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    name: displayName,
                    seed: user.avatarSeed,
                    size: 48,
                    imageURL: user.avatarURL,
                    avatarVersion: user.avatarVersion,
                    avatarUpdatedAt: user.avatarUpdatedAt,
                    certification: state.certificationPresentation(
                        forExactUID: user.id
                    )
                )
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: user.id,
                            compact: true
                        )
                    }
                    Text(existingConversationID == nil ? "点击发起单聊" : "进入已有单聊")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(existingConversationID == nil ? IMColor.muted : IMColor.success)
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
                            .stroke(IMColor.brand.opacity(existingConversationID == nil ? 0.10 : 0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("start_direct_chat_contact_\(user.id)")
        .accessibilityLabel(
            [
                "发起单聊 \(displayName)",
                state.certificationPresentation(
                    forExactUID: user.id
                )?.accessibilityLabel
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
    }

    private func quickSheetHeader(symbol: String, title: String, subtitle: String) -> some View {
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
                dismiss()
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
        .plainCard(radius: 24)
    }
}

private struct FindUserSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var applyMessage = ""
    @State private var results: [UserSearchResult] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var applyingID: String?

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(alignment: .leading, spacing: 14) {
                    quickSheetHeader(
                        symbol: "person.text.rectangle.fill",
                        title: "查找用户",
                        subtitle: "通过用户 ID 搜索当前企业用户，并发起好友申请。"
                    )

                    searchInput

                    VStack(alignment: .leading, spacing: 8) {
                        Text("申请备注")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                        TextField("输入好友申请备注", text: $applyMessage)
                            .font(.system(size: 14, weight: .semibold))
                            .textInputAutocapitalization(.never)
                            .imReadableInputText()
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.92)))
                            .accessibilityIdentifier("find_user_apply_message_input")
                    }
                    .plainCard(radius: 22)

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            if isSearching {
                                ProgressView("正在搜索")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                                    .plainCard(radius: 24)
                            } else if !hasSearched {
                                EmptyStateView(
                                    symbol: "person.crop.circle.badge.questionmark",
                                    title: "输入用户 ID",
                                    subtitle: "仅搜索当前企业内可见用户，搜索不到时不会生成任何本地结果。"
                                )
                            } else if results.isEmpty {
                                EmptyStateView(
                                    symbol: "magnifyingglass",
                                    title: "未找到用户",
                                    subtitle: "请确认用户 ID 是否正确，或该用户是否属于当前企业。"
                                )
                            } else {
                                ForEach(results) { item in
                                    userResultRow(item)
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
                    Button("关闭") { dismiss() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IMColor.brand)
                        .accessibilityIdentifier("find_user_close_button")
                }
            }
            .onAppear {
                if applyMessage.isEmpty {
                    applyMessage = "我是 \(state.currentUser.name)"
                }
            }
            .onChangeCompat(of: state.avatarRealtimePresentationRevision) { _, _ in
                results = state.projectAvatarRealtime(results)
            }
        }
    }

    private var searchInput: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(IMColor.muted)
            TextField("输入用户 ID", text: $keyword)
                .font(.system(size: 15, weight: .bold))
                .imReadableInputText()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { performSearch() }
                .accessibilityIdentifier("find_user_search_input")
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    results = []
                    hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.muted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("find_user_clear_button")
            }
            Button {
                performSearch()
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

    private func userResultRow(_ item: UserSearchResult) -> some View {
        let liveItem = item
        return HStack(spacing: 12) {
                AvatarView(
                    name: liveItem.displayName,
                    seed: userSearchSeed(liveItem.id),
                    size: 48,
                    imageURL: liveItem.avatarURL,
                    certification: state.certificationPresentation(
                        forExactUID: liveItem.id
                    )
                )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(liveItem.displayName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: liveItem.id,
                        compact: true
                    )
                    relationPill(liveItem)
                }
                CopyableUserIDText(
                    value: liveItem.userID.isEmpty ? liveItem.id : liveItem.userID,
                    prefix: "用户 ID：",
                    font: .system(size: 12, weight: .semibold),
                    color: IMColor.muted
                )
                if !liveItem.phone.isEmpty {
                    Text("手机号：\(liveItem.phone)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            applyButton(liveItem)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(liveItem.canApplyFriend ? IMColor.brand.opacity(0.18) : IMColor.line, lineWidth: 1)
                )
        )
        .accessibilityIdentifier("find_user_result_\(liveItem.id)")
    }

    private func relationPill(_ item: UserSearchResult) -> some View {
        Text(relationTitle(item))
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(relationColor(item))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(relationColor(item).opacity(0.12)))
    }

    private func applyButton(_ item: UserSearchResult) -> some View {
        let canApply = canSubmitFriendRequest(item)
        return Button {
            apply(item)
        } label: {
            Group {
                if applyingID == item.id {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(canApply ? FriendAddPresentation.actionTitle : actionTitle(item))
                        .font(.system(size: 12, weight: .black))
                }
            }
            .foregroundStyle(canApply ? .white : IMColor.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 92, height: 36)
            .background(Capsule().fill(canApply ? IMColor.brand : IMColor.page))
        }
        .buttonStyle(.plain)
        .disabled(!canApply || applyingID != nil)
        .accessibilityIdentifier("find_user_apply_\(item.id)")
        .accessibilityLabel("添加好友 \(item.displayName)")
    }

    private func canSubmitFriendRequest(_ item: UserSearchResult) -> Bool {
        state.canCurrentUserInitiateFriendRequest && item.canApplyFriend
    }

    private func performSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.toast = "请输入用户 ID"
            return
        }
        isSearching = true
        hasSearched = true
        Task {
            let items = await state.searchTenantUsers(keyword: trimmed)
            await MainActor.run {
                results = state.projectAvatarRealtime(items)
                isSearching = false
            }
        }
    }

    private func apply(_ item: UserSearchResult) {
        guard applyingID == nil else { return }
        applyingID = item.id
        Task {
            let updated = await state.applyFriendFromSearch(item, message: applyMessage)
            await MainActor.run {
                if let updated, let index = results.firstIndex(where: { $0.id == updated.id }) {
                    results[index] = updated
                }
                applyingID = nil
            }
        }
    }

    private func relationTitle(_ item: UserSearchResult) -> String {
        switch item.relationStatus {
        case "friend": return "已是好友"
        case "pending_in": return "待我处理"
        case "pending_out": return FriendAddPresentation.waitingTitle
        case "blocked": return "不可添加"
        case "self": return "本人"
        default: return canSubmitFriendRequest(item) ? "可添加" : "不可添加"
        }
    }

    private func actionTitle(_ item: UserSearchResult) -> String {
        if item.canApplyFriend && !state.canCurrentUserInitiateFriendRequest {
            return "已关闭"
        }
        switch item.relationStatus {
        case "friend": return "好友"
        case "pending_in": return "待处理"
        case "pending_out": return FriendAddPresentation.waitingTitle
        case "self": return "本人"
        default: return "不可用"
        }
    }

    private func relationColor(_ item: UserSearchResult) -> Color {
        switch item.relationStatus {
        case "friend": return IMColor.success
        case "pending_in", "pending_out": return IMColor.warning
        case "blocked": return IMColor.danger
        case "self": return IMColor.muted
        default: return canSubmitFriendRequest(item) ? IMColor.brand : IMColor.muted
        }
    }

    private func userSearchSeed(_ key: String) -> UInt {
        key.unicodeScalars.reduce(UInt(5381)) { partial, scalar in
            ((partial << 5) &+ partial) &+ UInt(scalar.value)
        }
    }

    private func quickSheetHeader(symbol: String, title: String, subtitle: String) -> some View {
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
                dismiss()
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
        .plainCard(radius: 24)
    }
}

struct EnterpriseCard: View {
    let enterprise: Enterprise
    var isSwitchingEnabled = true
    var action: () -> Void

    var body: some View {
        EnterpriseHeaderCard(enterprise: enterprise, isSwitchingEnabled: isSwitchingEnabled, action: action) {
            EmptyView()
        }
    }
}

private struct AnnouncementBanner: View {
    @EnvironmentObject private var state: AppState
    let items: [InboxItem]
    @Binding var selection: Int
    @Binding var selectedItem: InboxItem?

    private let timer = Timer.publish(every: 5.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyView()
            } else {
                let safeIndex = items.indices.contains(selection) ? selection : 0
                let item = items[safeIndex]
                HStack(spacing: 10) {
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(IMColor.brand))

                    Button {
                        selectedItem = item
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("公告")
                                        .font(.system(size: 12, weight: .black))
                                        .foregroundStyle(IMColor.brand)
                                    if !item.isRead {
                                        Circle()
                                            .fill(IMColor.danger)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                Text(item.title)
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(IMColor.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(item.time)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(height: 58)
                    .onReceive(timer) { _ in
                        guard items.count > 1 else { return }
                        selection = (selection + 1) % items.count
                    }

                    Spacer()

                    Button {
                        state.networkBannerVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.brand.opacity(0.09)))
            }
        }
    }
}

// JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRIVATE_SCOPE - 修改开始：会话行仅在当前文件使用，配合私有展示缓存
private struct ConversationRow: View {
// JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRIVATE_SCOPE - 修改结束：会话行仅在当前文件使用，配合私有展示缓存
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：实际行视图只依赖轻量展示模型
    let rowModel: ConversationRowModel
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    var mentionTarget: String = ""
    var unreadMention: MentionPreview?
    var systemNoticeAvatarURL: String = ""
    private let listAvatarSize: CGFloat = 56

    private var displayTitle: String {
        rowModel.displayTitle
    }

    private var rowPresentation: ConversationRowPresentation {
        rowModel.rowPresentation
    }

    private var unreadBadgeColor: Color {
        rowModel.isMuted ? IMColor.muted.opacity(0.62) : IMColor.danger
    }

    private var reactionUnreadColor: Color {
        rowModel.isMuted ? IMColor.warning.opacity(0.12) : IMColor.warning.opacity(0.18)
    }

    private var reactionUnreadTextColor: Color {
        rowModel.isMuted ? IMColor.warning.opacity(0.72) : IMColor.warning
    }

    private var shouldShowReactionUnreadBadge: Bool {
        rowModel.hasUnreadReaction || rowModel.unreadReactionCount > 0
    }

    private var conversationTag: (title: String, color: Color)? {
        switch rowModel.kind {
        case .group:
            return ("群", IMColor.warning)
        case .system:
            return ("系", IMColor.cyan)
        case .direct:
            return nil
        }
    }

    private var displayTime: String {
        conversationListDisplayTime(rawTime: rowModel.time, sortTimestamp: rowModel.sortTimestamp)
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomLeading) {
                if rowModel.kind == .system {
                    SystemConversationAvatar(size: listAvatarSize, imageURL: systemNoticeAvatarURL)
                } else if rowModel.kind == .group {
                    // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_GROUP_AVATAR_CACHE - 修改开始：复用会话列表缓存里的群头像 key
                    GroupAvatarView(name: displayTitle, seed: rowModel.accentHex, size: listAvatarSize, imageURL: rowPresentation.avatarURL, avatarVersion: rowPresentation.avatarVersion, avatarUpdatedAt: rowPresentation.avatarUpdatedAt, imageCacheKey: rowPresentation.avatarImageCacheKey)
                    // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_GROUP_AVATAR_CACHE - 修改结束：复用会话列表缓存里的群头像 key
                } else {
                    // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_DIRECT_AVATAR_CACHE - 修改开始：直聊头像和认证展示使用缓存字段
                    AvatarView(name: displayTitle, seed: rowModel.accentHex, size: listAvatarSize, imageURL: rowPresentation.avatarURL, avatarVersion: rowPresentation.avatarVersion, avatarUpdatedAt: rowPresentation.avatarUpdatedAt, certification: rowPresentation.directCertificationPresentation)
                    // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_DIRECT_AVATAR_CACHE - 修改结束：直聊头像和认证展示使用缓存字段
                }
                if let conversationTag {
                    ConversationTypeBadge(title: conversationTag.title, color: conversationTag.color)
                        .offset(x: -4, y: 4)
                }
            }
            .frame(width: listAvatarSize, height: listAvatarSize)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    if rowModel.kind == .direct {
                        CertificationPillView(
                            exactUID: rowPresentation.directCertificationUID,
                            compact: true,
                            // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_DIRECT_CERT_CACHE - 修改开始：认证徽标优先使用缓存展示，减少滑动中同步读取
                            presentation: rowPresentation.directCertificationPresentation
                            // JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_DIRECT_CERT_CACHE - 修改结束：认证徽标优先使用缓存展示，减少滑动中同步读取
                        )
                    }
                    if rowModel.isPinned {
                        ConversationStatusChip(
                            symbol: "pin.fill",
                            title: "置顶",
                            color: IMColor.warning,
                            fill: Color(hex: 0xFFF1C7)
                        )
                    }
                    if rowModel.isMuted {
                        ConversationStatusChip(
                            symbol: "bell.slash.fill",
                            title: "免扰",
                            color: IMColor.muted,
                            fill: Color(hex: 0xEEF2FA)
                        )
                    }
                }
                summaryText
                    .font(.system(size: 13, weight: unreadMention == nil ? .medium : .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                if !displayTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(displayTime)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                if let unreadText = UnreadBadgeFormatter.text(rowModel.unread) {
                    HStack(spacing: 5) {
                        if shouldShowReactionUnreadBadge {
                            Text("[表情]")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(reactionUnreadTextColor)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(Capsule().fill(reactionUnreadColor))
                        }
                        Text(unreadText)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Capsule().fill(unreadBadgeColor))
                    }
                }
            }
        }
        .padding(14)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(rowModel.isPinned ? Color(hex: 0xFFF8E2) : .white.opacity(0.90))
                if rowModel.isPinned {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(IMColor.warning)
                        .frame(width: 4)
                        .padding(.vertical, 15)
                        .padding(.leading, 1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(rowModel.isPinned ? IMColor.warning.opacity(0.38) : IMColor.line)
            )
            .shadow(color: rowModel.isPinned ? IMColor.warning.opacity(0.10) : .clear, radius: 10, y: 5)
        )
    }

    private var summaryText: Text {
        guard let unreadMention else {
            return Text(rowModel.lastMessage).foregroundColor(IMColor.muted)
        }
        let prefix = "\(unreadMention.senderName)："
        return Text(prefix).foregroundColor(IMColor.muted) + highlightedMentionText(unreadMention.text, target: mentionTarget, baseColor: IMColor.muted)
    }
}

private struct ConversationStatusChip: View {
    let symbol: String
    let title: String
    let color: Color
    let fill: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
            Text(title)
                .font(.system(size: 9, weight: .black))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(color.opacity(0.24), lineWidth: 0.8))
    }
}

private func highlightedMentionText(_ text: String, target: String, baseColor: Color) -> Text {
    if text.localizedCaseInsensitiveContains("@所有人") {
        return highlightedMentionText(text, targets: ["@所有人", target].filter { !$0.isEmpty }, baseColor: baseColor)
    }
    guard !target.isEmpty else {
        return Text(text).foregroundColor(baseColor)
    }

    var result = Text("")
    var cursor = text.startIndex
    var found = false

    while let range = text.range(of: target, options: .caseInsensitive, range: cursor..<text.endIndex) {
        found = true
        if cursor < range.lowerBound {
            result = result + Text(String(text[cursor..<range.lowerBound])).foregroundColor(baseColor)
        }
        result = result + Text(String(text[range])).foregroundColor(IMColor.danger)
        cursor = range.upperBound
    }

    if cursor < text.endIndex {
        result = result + Text(String(text[cursor..<text.endIndex])).foregroundColor(baseColor)
    }

    return found ? result : Text(text).foregroundColor(baseColor)
}

private func highlightedMentionText(_ text: String, targets: [String], baseColor: Color) -> Text {
    var result = Text("")
    var cursor = text.startIndex
    var found = false
    while cursor < text.endIndex {
        let matches = targets.compactMap { target -> (Range<String.Index>, String)? in
            guard let range = text.range(of: target, options: .caseInsensitive, range: cursor..<text.endIndex) else { return nil }
            return (range, target)
        }
        guard let match = matches.sorted(by: { lhs, rhs in
            if lhs.0.lowerBound == rhs.0.lowerBound { return lhs.0.upperBound > rhs.0.upperBound }
            return lhs.0.lowerBound < rhs.0.lowerBound
        }).first else {
            result = result + Text(String(text[cursor..<text.endIndex])).foregroundColor(baseColor)
            break
        }
        found = true
        if cursor < match.0.lowerBound {
            result = result + Text(String(text[cursor..<match.0.lowerBound])).foregroundColor(baseColor)
        }
        result = result + Text(String(text[match.0])).foregroundColor(match.1 == "@所有人" ? IMColor.warning : IMColor.danger)
        cursor = match.0.upperBound
    }
    return found ? result : Text(text).foregroundColor(baseColor)
}

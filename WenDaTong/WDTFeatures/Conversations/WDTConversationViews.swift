import IM4Features
import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110
import UIKit

struct ConversationListRoute: Identifiable, Hashable {
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

final class ConversationStoreChangeCoalescer {
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
enum ConversationListLagDiagnostics {
    static let hitchProbeIntervalNS: UInt64 = 250_000_000
    static let hitchProbeIntervalMS = 250

    static func elapsedMS(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
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
        DebugConsoleDiagnostics.trace(line)
        ConversationListLagTraceRecorder.record(line)
    }
}
#endif
// JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_VIEW - 修改结束

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
struct ConversationListView: View {
    @State private var observedCurrentUser: IMUser?
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }

    @EnvironmentObject var state: AppState
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @State var query = ""
    @State var filter = "全部"
    @State var selectedConversationRoute: ConversationListRoute?
    @State private var globalSearchPresentation: TenantGlobalSearchPresentation? // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113
    @State private var actionConversation: ConversationMessageSnapshot?
    @State private var showEnterpriseSheet = false
    @State private var announcementIndex = 0
    @State private var selectedAnnouncement: InboxItem?
    // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_BEGIN
    @State private var observedGroupDirectory: [GroupInfo]?
    @State private var observedContactDirectory: ContactStore.DirectoryPresentationSnapshot?
    @State private var observedCertificationRevision: Int? // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_BEGIN
    @State var observedHasConversations: Bool?
    @State private var observedAlertingUnreadTotal: Int?
    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_END
    // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_END
    @State var cachedConversationSections: ConversationRenderSections = .empty
    @State var conversationRowsRevision = 0
    @State var conversationListMemoryChanges = ConversationListMemoryChanges() // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112
    @State var cachedMentionRecords: [MentionMessageRecord] = []
    @State var cachedUnreadMentionCount = 0
    @State var cachedAnnouncementItems: [InboxItem] = []
    @State var conversationCacheRebuildTask: Task<Void, Never>?
    @State var conversationStoreChangeCoalescer = ConversationStoreChangeCoalescer()
    @State var conversationRowProjectionCache = ConversationRowProjectionCache()
    // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：聊天页覆盖列表时只记录 UI 缓存脏标记，避免不可见列表抢主线程重建
    @State var conversationRenderCacheDirtyWhileRouteActive = false
    // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
    @State var listClockTick = Date()
    @State var isConversationListInteracting = false
    @State var conversationRenderCacheDirtyWhileInteracting = false
    // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_STATE - 修改开始：仅在会话列表可见时运行主线程延迟探针
    #if DEBUG
    @State private var conversationListHitchMonitorTask: Task<Void, Never>?
    #endif
    // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_STATE - 修改结束

    private let filters = ["全部", "未读", "@我"]
    private let conversationListCoordinateSpaceName = "conversation-list-scroll"

    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_BEGIN
    var body: some View {
#if DEBUG
        let _ = ChatTimelineRenderDiagnostics.conversationListBody?(self)
#endif
        currentUserObservedContent(currentUserSnapshot: renderedCurrentUser)
            .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)) { user in
                if observedCurrentUser != user { observedCurrentUser = user }
            }
    }

    @ViewBuilder
    private func currentUserObservedContent(currentUserSnapshot: IMUser) -> some View {
        state.conversationListPresentationStore.observe { presentation in
            // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_BEGIN
            state.bootstrapPresentationStore.observeSync({ $0 }) { sync in
                // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_BEGIN
                state.tenantInteractionStore.observe(\.showsProcessingNotices) { showsNotices in
                    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
                    state.tenantClientPolicyStore.observe(\.showsGroupMemberCount) { showsGroupCount in
                        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                        state.enterpriseMembershipStore.observe(\.current) { enterprise in
                            conversationListContent(presentation, sync: sync, showsNotices: showsNotices, showsGroupCount: showsGroupCount, enterprise: enterprise)
                        }
                        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
                    }
                    // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
                }
                // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110_END
            }
            // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110_END
        }
    }
    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_END

    @ViewBuilder
    private func conversationListContent(_ presentation: ConversationListPresentationStore.Snapshot, sync: BootstrapPresentationStore.Sync, showsNotices: Bool, showsGroupCount: Bool, enterprise: Enterprise) -> some View { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
        let conversationSections = filter == "@我" ? ConversationRenderSections.empty : cachedConversationSections
        let renderMatchingConversations = conversationSections.ordered

        ConversationListScreenContent {
            RecycledConversationTable(
                sections: conversationSections,
                rowsRevision: conversationRowsRevision,
                displaysRows: filter != "@我", // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113
                searchRevision: filter == "@我" ? "@我|\(query)" : "", // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113
                rowContext: mentionTarget + "|" + state.systemNoticeAvatarURL + "|" + String(Int(listClockTick.timeIntervalSince1970 / 60)),
                header: recycledConversationHeader(showsAnnouncements: presentation.showsAnnouncements, enterprise: enterprise).appStateEnvironment(state), // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                search: PinnedSearchHeader { conversationSearchHeader }.appStateEnvironment(state), // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113
                filter: filterBar.padding(.horizontal, 18).padding(.bottom, 18).appStateEnvironment(state),
                footer: recycledConversationFooter(sync: sync).environment(\.tenantShowsGroupMemberCount, showsGroupCount).environment(\.chatShowsMessageProcessingNotices, showsNotices).appStateEnvironment(state), // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                headerRevision: ConversationListHeaderRevision(enterprise: enterprise, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                    announcementIndex: announcementIndex, announcements: cachedAnnouncementItems,
                    showsAnnouncements: presentation.showsAnnouncements), // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                filterRevision: "\(filter)|\(UnreadBadgeFormatter.text(alertingUnreadTotal) ?? "")|\(UnreadBadgeFormatter.text(cachedUnreadMentionCount) ?? "")",
                dynamicFooter: filter == "@我" || renderMatchingConversations.isEmpty || sync.isLoadingMoreConversations || sync.isConversationSnapshotPartial, // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                interactionChanged: { interacting in
                    isConversationListInteracting = interacting
                    state.isConversationListUserInteracting = interacting
                    if interacting {
                        if conversationCacheRebuildTask != nil {
                            conversationRenderCacheDirtyWhileInteracting = true
                            conversationCacheRebuildTask?.cancel()
                            conversationCacheRebuildTask = nil
                        }
                    } else if conversationRenderCacheDirtyWhileInteracting {
                        conversationRenderCacheDirtyWhileInteracting = false
                        scheduleConversationRenderCacheRebuild()
                    }
                },
                row: { item in conversationRow(for: item).padding(.horizontal, 18).padding(.bottom, 12).appStateEnvironment(state).environment(\.tenantShowsGroupMemberCount, showsGroupCount) } // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
            )
        }
        .onAppear {
            listClockTick = conversationListProjectionDate() // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
            // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_LIFECYCLE - 修改开始：进入会话列表时启动主线程卡顿探针
            #if DEBUG
            startConversationListHitchMonitor()
            #endif
            // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_LIFECYCLE - 修改结束
            applyNotificationConversationOpenRequest(state.conversationListPresentationStore.snapshot.notificationOpenRequest) // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
            // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
            let store = state.conversationStore.messageMemoryStore
            if conversationListMemoryChanges.needsRebind(to: store)
                || conversationListMemoryChanges.projectedRevision != store.revision {
                rebuildAllRenderCaches()
            }
            // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END
        }
        // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_BEGIN
        // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
        .onReceive(state.conversationStore.memoryCommits) { commit in
            guard commit.bindingID == state.conversationStore.messageMemoryStore.bindingID else { return }
            let hasConversations = !commit.current.conversations.isEmpty
            if observedHasConversations != hasConversations {
                observedHasConversations = hasConversations
            }
            receiveConversationMemoryCommit(commit)
        }
        // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END
        .onReceive(state.conversationStore.alertingUnreadUpdates) { total in
            if observedAlertingUnreadTotal != total { observedAlertingUnreadTotal = total }
        }
        // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_END
        // WDT_APP_CONTRACT_20261021_05: policy and directory totals invalidate cached row badges.
        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
        .onChangeCompat(of: enterprise.name) { _, _ in
            invalidateConversationRowProjections()
            rebuildConversationRenderCaches()
        }
        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
        .onChangeCompat(of: showsGroupCount) { _, showCount in // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
            invalidateConversationRowProjections()
            rebuildConversationRenderCaches()
            if showCount {
                Task { await state.refreshGroupDirectory(silent: true) }
            }
        }
        .onChangeCompat(of: showsNotices) { _, _ in // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
            invalidateConversationRowProjections()
            rebuildConversationRenderCaches()
        }
        // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.groupDirectoryUpdates) { snapshot in
            // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_BEGIN
            // SwiftUI can resubscribe during a body update. An initial replay
            // must not restart the cache timer for the snapshot already seen.
            guard observedGroupDirectory != snapshot else { return }
            observedGroupDirectory = snapshot
            // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_END
            invalidateConversationRowProjections()
            scheduleConversationRenderCacheRebuild()
        }
        // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.announcementUpdates) { items in
            rebuildAnnouncementCache(from: items)
        }
        // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END
        // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
        .onChangeCompat(of: query) { _, _ in
            if filter == "@我" { rebuildQueryDependentCaches() }
        }
        .onChangeCompat(of: filter) { _, _ in
            rebuildQueryDependentCaches()
        }
        // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END
        .onChangeCompat(of: CurrentUserPresentationStore.identity(renderedCurrentUser)) { _, _ in
            rebuildQueryDependentCaches()
        }
        .onChangeCompat(of: renderedCurrentUser.name) { _, _ in
            rebuildQueryDependentCaches()
        }
        // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_REFRESH - 修改开始：联系人/认证展示变化时刷新列表行缓存
        // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.directoryPresentationUpdates) { snapshot in
            // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_BEGIN
            // SwiftUI can resubscribe during a body update. An initial replay
            // must not restart the cache timer for the snapshot already seen.
            guard observedContactDirectory != snapshot else { return }
            observedContactDirectory = snapshot
            // WDT_IOS1_REFACTOR_CONTACT_RELAY_RETIREMENT_20261110_END
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：联系人资料会影响直聊头像和展示名，强制刷新渲染输入签名
            invalidateConversationRowProjections()
            // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改结束
            scheduleConversationRenderCacheRebuild()
        }
        // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_END
        .onReceive(state.certificationPresentationStore.changes) { revision in
            // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
            guard observedCertificationRevision != revision else { return }
            let hasPreviousRevision = observedCertificationRevision != nil
            observedCertificationRevision = revision
            guard hasPreviousRevision else { return }
            // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_RENDER_20260912 - 修改开始：认证展示变化会影响行内角标，强制刷新渲染输入签名
            invalidateConversationRowProjections()
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
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                listClockTick = conversationListProjectionDate(now) // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
            }
        }
        .onDisappear {
            isConversationListInteracting = false
            state.isConversationListUserInteracting = false
            conversationRenderCacheDirtyWhileInteracting = false
            conversationStoreChangeCoalescer.cancelPending()
            conversationCacheRebuildTask?.cancel()
            conversationCacheRebuildTask = nil
            // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_HITCH_STOP - 修改开始：离开会话列表时停止卡顿探针
            #if DEBUG
            stopConversationListHitchMonitor()
            #endif
            // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_HITCH_STOP - 修改结束
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            requiredChatRouting(chatFeatureRouting).makeChat(
                route.conversationID,
                initialSearchJumpTarget: route.initialSearchJumpTarget
            )
        }
        .onChangeCompat(of: presentation.returnToken) { _, token in // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
            // 退群/解散群成功:关闭当前会话页(其上的群详情/确认弹窗随之收起),
            // 直接回到会话列表。
            guard token > 0 else { return }
            selectedConversationRoute = nil
        }
        .onChangeCompat(of: presentation.notificationOpenRequest) { _, request in // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
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
        // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
        .fullScreenCover(item: $globalSearchPresentation) { presentation in
            TenantGlobalSearchPage(presentation: presentation)
                .appStateEnvironment(state)
        }
        // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END
    }

    // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
    @ViewBuilder private var conversationSearchHeader: some View {
        if filter == "@我" {
            SearchField(text: $query, placeholder: "搜索@我的消息")
                .accessibilityIdentifier("conversation_mention_search_field")
        } else {
            Button(action: openGlobalSearch) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("搜索联系人、群聊、聊天记录、文件")
                        .lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.82))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation_search_field")
        }
    }

    func openGlobalSearch() {
        guard state.apiContext.hasIMSession else { return }
        globalSearchPresentation = TenantGlobalSearchPresentation(
            owner: state.chatBubbleSessionIdentity,
            deployment: state.apiContext.tenantAPIBaseURL,
            returnToken: state.conversationListPresentationStore.snapshot.returnToken
        )
    }
    // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END

    private func recycledConversationHeader(showsAnnouncements: Bool, enterprise: Enterprise) -> some View { // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
VStack(alignment: .leading, spacing: 18) {
                            ConversationTopCard(enterprise: enterprise) { // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                                showEnterpriseSheet = true
                            } openConversation: { conversationID in
                                openConversation(conversationID)
                            }
                            if showsAnnouncements && !cachedAnnouncementItems.isEmpty { // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                                AnnouncementBanner(
                                    items: cachedAnnouncementItems,
                                    selection: $announcementIndex,
                                    selectedItem: $selectedAnnouncement,
                                    onDismiss: { state.conversationListPresentationStore.snapshot.showsAnnouncements = false } // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
                                )
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
    }

    @ViewBuilder private func recycledConversationFooter(sync: BootstrapPresentationStore.Sync) -> some View { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_BEGIN
        ConversationListFooterContent(isGlobalSearchActive: false, isInitialLoading: sync.isInitialLoading,
            syncFailureMessage: sync.syncFailureMessage, isSyncRetrying: sync.isSyncRetrying,
            isLoadingMoreConversations: sync.isLoadingMoreConversations, isConversationSnapshotPartial: sync.isConversationSnapshotPartial,
            hasConversations: hasConversations, matchesAreEmpty: cachedConversationSections.ordered.isEmpty,
            queryIsEmpty: trimmedSearchQuery.isEmpty, filter: filter, search: { EmptyView() }, mentions: {
                MentionMessageList(records: cachedMentionRecords, mentionTarget: mentionTarget) { record in
                    openConversation(
                        record.conversationID,
                        initialSearchJumpTarget: mentionJumpTarget(for: record)
                    )
                }
            }, onRetry: { state.retryRemoteSync() }, onClear: {
                query = ""
                filter = "全部"
            })
        // WDT_IOS1_GLOBAL_SEARCH_PAGE_20261113_END
    }

    private func conversationRow(for item: ConversationRenderItem) -> some View {
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：交互行使用轻量展示模型，点击/长按仍沿用原会话业务对象
        let rowModel = item.rowModel
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        return ConversationInteractiveRow(
            rowModel: rowModel,
            directCertificationPresentation: item.directCertificationPresentation,
            mentionTarget: mentionTarget,
            unreadMention: item.unreadMention,
            systemNoticeAvatarURL: state.systemNoticeAvatarURL
        ) {
            guard let conversation = state.conversationStore.conversationMessageSnapshot(id: item.id) else { return }
            if conversation.kind == .system, conversation.unread > 0 {
                state.markConversationRead(conversation.id, showToast: false)
            }
            openConversation(
                conversation.id,
                initialSearchJumpTarget: earliestUnreadMentionJumpTarget(in: conversation)
            )
        } onLongPress: {
            guard let conversation = state.conversationStore.conversationMessageSnapshot(id: item.id) else { return }
            guard conversationListSupportsMutableActions(conversation.conversation) else { return }
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
                    let line = "[JHT Perf] conversation_list_hitch drift_ms=\(driftMS) interval_ms=\(elapsedMS) visible_count=\(cachedConversationSections.ordered.count) source_count=\(state.conversationStore.conversations.count) filter=\(filter) has_query=\(!trimmedSearchQuery.isEmpty)"
                    DebugConsoleDiagnostics.trace(line)
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

    func openConversation(
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

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("早上好，\(renderedCurrentUser.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: renderedCurrentUser.id,
                        compact: true
                    )
                }
                Text("企业 IM 工作台")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(IMColor.ink)
            }
            Spacer()
            AvatarView(name: renderedCurrentUser.name, seed: renderedCurrentUser.avatarSeed, size: 48, imageURL: renderedCurrentUser.avatarURL, avatarVersion: renderedCurrentUser.avatarVersion, avatarUpdatedAt: renderedCurrentUser.avatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: renderedCurrentUser.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }
    }

    private var filterBar: some View {
        ConversationFiltersContent(filters: filters, selection: $filter,
            counts: Dictionary(uniqueKeysWithValues: filters.compactMap { item in
                filterCount(for: item).map { (item, $0) }
            }))
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_BEGIN
    private var hasConversations: Bool {
        observedHasConversations ?? !state.conversationStore.conversations.isEmpty
    }

    private var alertingUnreadTotal: Int {
        observedAlertingUnreadTotal ?? state.conversationStore.alertingUnreadTotal
    }
    // WDT_IOS1_REFACTOR_CONVERSATION_LIST_AND_SHEET_OBSERVATION_20261110_END

    private func filterCount(for item: String) -> Int? {
        switch item {
        case "全部":
            alertingUnreadTotal > 0 ? alertingUnreadTotal : nil
        case "未读":
            alertingUnreadTotal > 0 ? alertingUnreadTotal : nil
        case "@我":
            cachedUnreadMentionCount > 0 ? cachedUnreadMentionCount : nil
        default:
            nil
        }
    }

}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private struct ConversationListTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

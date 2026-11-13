// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110
import PhotosUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import SwiftUI
import IM4Features
import UIKit
// WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110: shared contact helpers are in ContactCommonRows.swift.
// WDT_IOS1_REALTIME_COMPUTE_CURRENT_ADAPT_20261110: unchanged ContactsConversationRoute moved to shared ContactCommonRows.swift.

private typealias ContactContentTab = IM4Features.ContactContentTab

// JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_MODEL - 修改开始：通讯录行预渲染模型，滚动时不再反复读取全局状态计算展示字段
struct ContactDirectoryGroup: Identifiable, Equatable {
    let letter: String
    let rows: [ContactDirectoryRowPresentation]

    var id: String { letter }
}

struct ContactDirectoryRowPresentation: Identifiable, Equatable {
    let user: IMUser
    let displayName: String
    let userNumber: String?
    let departmentSummary: String?
    let certification: CertificationPresentation?
    let accessibilityPrefix: String

    var id: String { user.id }

    var accessibilityLabel: String {
        [
            "\(accessibilityPrefix) \(displayName)",
            userNumber.map { "用户编号 \($0)" },
            certification?.accessibilityLabel
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

@MainActor
func contactDirectoryRowPresentation(
    for user: IMUser,
    state: AppState,
    includeDepartmentSummary: Bool,
    accessibilityPrefix: String = "联系人",
    displayName: String? = nil
) -> ContactDirectoryRowPresentation {
    return ContactDirectoryRowPresentation(
        user: user,
        displayName: displayName ?? state.contactDirectoryDisplayName(for: user),
        userNumber: contactAuthoritativeUserNumber(userID: user.userID),
        departmentSummary: includeDepartmentSummary ? state.departmentSummary(for: user) : nil,
        certification: state.certificationPresentation(forExactUID: user.id),
        accessibilityPrefix: accessibilityPrefix
    )
}
// JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_ROW_PRESENTATION_MODEL - 修改结束：通讯录行预渲染模型，滚动时不再反复读取全局状态计算展示字段

struct ContactsView: View {
    @Environment(\.contactsFeatureRouting) private var contactsFeatureRouting
    @Environment(\.chatFeatureRouting) private var chatFeatureRouting
    @EnvironmentObject private var state: AppState
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext
    @State private var appliedQuery = ""
    @State private var contactSearchDraft = ""
    @State private var selectedRoute: ContactRoute?
    @State private var selectedUser: IMUser?
    // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_CONTACTS_ROUTE_STATE - 修改开始：联系人页聊天跳转改为稳定 item route
    @State private var selectedConversationRoute: ContactsConversationRoute?
    // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CONTACTS_ROUTE_STATE - 修改结束
    @State private var activeContentTab: ContactContentTab = .contacts
    @State private var cachedContactGroups = ContactDirectoryTableProjection(groups: [])
    @State private var cachedContactGroupsSignature = ""
    @State private var showingDepartmentManagement = false
    @State private var selectedOrganizationDepartment: RemoteDepartmentNode?
    @State private var isContactSearchEditing = false
    @State private var showingFindUser = false
    @State private var contactGroupsRebuildTask: Task<Void, Never>?
    @State private var isDirectoryVisible = false
    @State private var isDirectoryScrolling = false
    @State private var needsDirectoryRebuild = false
    @State private var needsGroupCountRefresh = false
    @State private var groupDirectoryRefreshTask: Task<Void, Never>?
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：伙伴 Tab 入口计数缓存与自动刷新节流，减少切换卡顿
    @State private var groupDirectoryRefreshGeneration = 0
    @State private var lastAutomaticGroupDirectoryRefreshAt: Date?
    @State private var cachedPendingFriendRequestCount = 0
    @State private var cachedProjectedGroupCount = 0
    @State private var cachedBlacklistCount = 0
    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
    @State private var observedContactsSync: ContactStore.ContactsSyncStatus?
    @State private var observedCertificationRevision: Int? // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    private let automaticGroupDirectoryRefreshInterval: TimeInterval = 45
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
    private let searchResultLimit = 20

    private var displayedContactGroups: [ContactDirectoryGroup] {
        cachedContactGroups.groups
    }

    private var isContactSearchActive: Bool {
        isContactSearchEditing || !trimmedContactSearchDraft.isEmpty || !appliedQuery.isEmpty
    }

    private var isContactSearchSettling: Bool {
        !trimmedContactSearchDraft.isEmpty && trimmedContactSearchDraft != appliedQuery
    }

    private var trimmedContactSearchDraft: String {
        contactSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedContactSearchResults: [ContactDirectoryRowPresentation] {
        Array(displayedContactGroups.flatMap(\.rows).prefix(searchResultLimit))
    }

    private func renderContactGroups() -> [ContactDirectoryGroup] {
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_RENDER_PRESENTATION_CACHE - 修改开始：联系人过滤/排序/展示字段统一预计算，减少滚动中逐行计算
        let trimmedQuery = appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldShowDepartment = state.isDepartmentFeatureEnabled
        let keyedContacts = state.contacts.compactMap { user -> (row: ContactDirectoryRowPresentation, sortKey: String, letter: String)? in
            let displayName = state.contactDirectoryDisplayName(for: user)
            guard trimmedQuery.isEmpty
                || IMUserSearchMatcher.matches(user: user, query: trimmedQuery)
                || contactDisplayNameMatches(displayName, query: trimmedQuery) else { return nil }
            let sortKey = contactSortKey(displayName)
            let row = contactDirectoryRowPresentation(
                for: user,
                state: state,
                includeDepartmentSummary: shouldShowDepartment,
                displayName: displayName
            )
            return (
                row: row,
                sortKey: sortKey,
                letter: contactInitial(forSortKey: sortKey)
            )
        }
        let sorted = keyedContacts.sorted {
            $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending
        }
        let capped = trimmedQuery.isEmpty ? sorted : Array(sorted.prefix(searchResultLimit))
        let grouped = Dictionary(grouping: capped, by: { $0.letter })
        let groups = grouped.keys.sorted(by: contactLetterSort).map { letter in
            ContactDirectoryGroup(letter: letter, rows: (grouped[letter] ?? []).map(\.row))
        }
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_RENDER_PRESENTATION_CACHE - 修改结束：联系人过滤/排序/展示字段统一预计算，减少滚动中逐行计算
        return groups
    }

    private func rebuildContactGroups() {
        cachedContactGroupsSignature = contactGroupsSignature()
        cachedContactGroups = ContactDirectoryTableProjection(groups: renderContactGroups(), previous: cachedContactGroups)
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_BATCH_PREFETCH - 修改开始：通讯录认证展示改为列表级批量预取，避免每行滚动出现时触发检查
        prefetchContactDirectoryCertifications(in: cachedContactGroups.groups)
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_BATCH_PREFETCH - 修改结束：通讯录认证展示改为列表级批量预取，避免每行滚动出现时触发检查
    }

    private func rebuildContactGroupsIfNeeded() {
        let signature = contactGroupsSignature()
        guard signature != cachedContactGroupsSignature else { return }
        cachedContactGroupsSignature = signature
        cachedContactGroups = ContactDirectoryTableProjection(groups: renderContactGroups(), previous: cachedContactGroups)
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_BATCH_PREFETCH_IF_NEEDED - 修改开始：缓存变化后统一预取通讯录认证展示，滚动时行视图保持轻量
        prefetchContactDirectoryCertifications(in: cachedContactGroups.groups)
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_BATCH_PREFETCH_IF_NEEDED - 修改结束：缓存变化后统一预取通讯录认证展示，滚动时行视图保持轻量
    }

    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
    var body: some View {
        state.observeDepartmentAvailability { departmentEnabled in
            directoryBody(departmentEnabled: departmentEnabled)
        }
    }

    private func directoryBody(departmentEnabled: Bool) -> some View {
    // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
        ContactsScreenContent(showsAlternate: (departmentEnabled && activeContentTab == .organization) || isContactSearchActive,
            search: { contactSearchHeader }, alternate: { alternateContactContent }, directory: {
                state.bootstrapPresentationStore.observeSync(\.isInitialLoading) { isInitialLoading in
                    recycledDirectory(isInitialLoading: isInitialLoading)
                }
            })
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestinationCompat(item: $selectedRoute) { route in
            switch route {
            case .newFriends:
                NewFriendsView()
            case .groupList:
                GroupListView()
            case .blacklist:
                BlacklistView()
            }
        }
        .navigationDestinationCompat(item: $selectedUser) { user in
            requiredContactsRouting(contactsFeatureRouting).makeUserProfile(user: user, onOpenConversation: { conversationID in
                // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_CONTACT_PROFILE_ROUTE - 修改开始：避免 Bool+Optional 跳转生成空聊天页
                selectedConversationRoute = ContactsConversationRoute(id: conversationID)
                // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CONTACT_PROFILE_ROUTE - 修改结束
            })
        }
        .navigationDestinationCompat(item: $selectedOrganizationDepartment) { department in
            OrganizationDepartmentMembersView(department: department)
        }
        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_CONTACTS_DESTINATION - 修改开始：聊天页目标由 route 直接携带
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            requiredChatRouting(chatFeatureRouting).makeChat(route.conversationID)
        }
        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CONTACTS_DESTINATION - 修改结束
        .onAppear {
            isDirectoryVisible = true
            rebuildContactGroupsIfNeeded()
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：切回伙伴页时复用缓存计数，自动群目录刷新短时间内只触发一次
            refreshContactQuickEntryCaches()
            startGroupDirectoryRefreshIfNeeded()
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        }
        .onDisappear {
            isDirectoryVisible = false
            contactGroupsRebuildTask?.cancel()
            contactGroupsRebuildTask = nil
            isDirectoryScrolling = false
            state.isContactDirectoryUserInteracting = false
            needsDirectoryRebuild = false
            needsGroupCountRefresh = false
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：取消隐藏页刷新时递增 generation，避免旧任务回写任务状态
            groupDirectoryRefreshGeneration += 1
            groupDirectoryRefreshTask?.cancel()
            groupDirectoryRefreshTask = nil
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        }
        // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.directoryPresentationUpdates) { _ in
            // The deferred rebuild reads the committed Store values.
            scheduleContactGroupsRebuild()
        }
        // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_END
        .onChangeCompat(of: departmentEnabled) { _, isEnabled in
            if !isEnabled {
                activeContentTab = .contacts
            }
            // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_DEPARTMENT_CACHE_REFRESH - 修改开始：部门展示开关变化时只重建通讯录展示缓存
            scheduleContactGroupsRebuild()
            // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_DEPARTMENT_CACHE_REFRESH - 修改结束：部门展示开关变化时只重建通讯录展示缓存
        }
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_PRESENTATION_CACHE_REFRESH - 修改开始：认证/部门数据变化时合并刷新通讯录展示缓存，避免滚动中逐行查状态
        .onReceive(state.certificationPresentationStore.changes) { revision in
            // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_BEGIN
            guard observedCertificationRevision != revision else { return }
            let hasPreviousRevision = observedCertificationRevision != nil
            observedCertificationRevision = revision
            guard hasPreviousRevision else { return }
            // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110_END
            scheduleContactGroupsRebuild()
        }
        .onReceive(state.organizationDirectoryStore.updates(\.membersByDepartment)) { _ in // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110
            guard state.isDepartmentFeatureEnabled else { return }
            scheduleContactGroupsRebuild()
        }
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_PRESENTATION_CACHE_REFRESH - 修改结束：认证/部门数据变化时合并刷新通讯录展示缓存，避免滚动中逐行查状态
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：入口卡片计数只在对应数据源变化时重算
        // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.$friendRequests) { requests in
            refreshPendingFriendRequestCountCache(from: requests)
        }
        // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.$groups) { groups in
            refreshProjectedGroupCountCache(groups: groups)
        }
        .onReceive(state.conversationStore.conversationUpdates) { conversations in // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            refreshProjectedGroupCountCache(conversations: conversations.map { ConversationMessageSnapshot(conversation: $0, messages: []) })
        }
        // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END
        // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
        // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_BEGIN
        .onReceive(state.contactStore.contactsSyncUpdates) { status in
            if observedContactsSync != status { observedContactsSync = status }
        }
        // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_END
        .onReceive(state.contactStore.blacklistUpdates) { items in
            refreshBlacklistCountCache(from: items)
        }
        // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        .sheet(isPresented: $showingFindUser) {
            FindUserSheet()
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(30)
        }
        .sheet(isPresented: $showingDepartmentManagement) {
            DepartmentManagementSheet()
                .environmentObject(state)
                .presentationDetentsCompat([.large])
                .presentationDragIndicatorCompat(.visible)
        }
    }

    private var contactSearchHeader: some View {
        PinnedSearchHeader {
            DebouncedContactsSearchField(
                placeholder: "搜索联系人、用户ID或拼音",
                onDraftChange: { contactSearchDraft = $0 },
                onEditingChange: { isContactSearchEditing = $0 },
                onQueryChange: applyContactSearchQuery
            )
        }
    }

    private func recycledDirectory(isInitialLoading: Bool) -> some View { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        let revision = ContactDirectoryHeaderRevision(
            showsTabs: state.isDepartmentFeatureEnabled,
            requests: cachedPendingFriendRequestCount,
            groups: cachedProjectedGroupCount,
            blacklist: cachedBlacklistCount,
            status: displayedContactGroups.isEmpty ? contactListStatus(isInitialLoading: isInitialLoading) : nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        )
        return ContactDirectoryTable(
            projection: cachedContactGroups, groupsRevision: cachedContactGroupsSignature,
            headerRevision: revision, state: state, avatarImageRouteContext: avatarImageRouteContext,
            header:
                VStack(alignment: .leading, spacing: 22) {
                    if revision.showsTabs {
                        contentTabs
                    }
                    quickEntries
                    VStack(alignment: .leading, spacing: 12) {
                        contactListTitle
                        if let status = revision.status {
                            contactStatusView(status)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, revision.status == nil ? 0 : 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            ,
            onSelect: { selectedUser = $0 },
            onScrollChange: directoryScrollChanged
        )
    }

    private var pendingFriendRequestSubtitle: String {
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：使用缓存的新朋友数量，避免 body 中重复 filter
        let visibleCount = UnreadBadgeFormatter.text(cachedPendingFriendRequestCount) ?? "0"
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        return "\(visibleCount) 个待处理"
    }

    private var quickEntries: some View {
        ContactQuickEntriesContent(pendingRequests: cachedPendingFriendRequestCount, groupCount: cachedProjectedGroupCount,
            blacklistCount: cachedBlacklistCount, pendingSubtitle: pendingFriendRequestSubtitle) { selectedRoute = $0 }
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：伙伴 Tab 自动刷新节流与入口计数缓存
    private func refreshContactQuickEntryCaches() {
        refreshPendingFriendRequestCountCache()
        refreshProjectedGroupCountCache()
        refreshBlacklistCountCache()
    }

    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110
    private func refreshPendingFriendRequestCountCache(from requests: [FriendRequest]? = nil) {
        let nextValue = (requests ?? state.contactStore.friendRequests).filter(\.isPendingIncoming).count
        guard cachedPendingFriendRequestCount != nextValue else { return }
        cachedPendingFriendRequestCount = nextValue
    }

    // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110
    private func refreshProjectedGroupCountCache(
        groups: [GroupInfo]? = nil, conversations: [ConversationMessageSnapshot]? = nil
    ) {
        guard isDirectoryVisible else { return }
        guard !isDirectoryScrolling else {
            needsGroupCountRefresh = true
            return
        }
        needsGroupCountRefresh = false
        // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_BEGIN
        let nextValue = ContactStore.projectedGroupDirectory(
            authoritativeGroups: groups ?? state.contactStore.groups,
            conversations: conversations ?? state.conversationStore.conversationMessageSnapshots()
        ).count
        // WDT_IOS1_REFACTOR_GROUP_DETAIL_OBSERVATION_20261110_END
        guard cachedProjectedGroupCount != nextValue else { return }
        cachedProjectedGroupCount = nextValue
    }

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110
    private func refreshBlacklistCountCache(from items: [BlacklistItem]? = nil) {
        let nextValue = (items ?? state.contactStore.blacklist).count
        guard cachedBlacklistCount != nextValue else { return }
        cachedBlacklistCount = nextValue
    }

    private func startGroupDirectoryRefreshIfNeeded() {
        guard groupDirectoryRefreshTask == nil else { return }
        let now = Date()
        if let lastAutomaticGroupDirectoryRefreshAt,
           now.timeIntervalSince(lastAutomaticGroupDirectoryRefreshAt) < automaticGroupDirectoryRefreshInterval {
            return
        }
        startGroupDirectoryRefresh(markAutomaticStartAt: now)
    }

    private func startGroupDirectoryRefresh(markAutomaticStartAt startedAt: Date? = nil) {
        groupDirectoryRefreshTask?.cancel()
        groupDirectoryRefreshGeneration += 1
        if let startedAt {
            lastAutomaticGroupDirectoryRefreshAt = startedAt
        }
        let generation = groupDirectoryRefreshGeneration
        groupDirectoryRefreshTask = Task { @MainActor in
            _ = await state.refreshGroupDirectory()
            guard !Task.isCancelled,
                  groupDirectoryRefreshGeneration == generation else {
                return
            }
            groupDirectoryRefreshTask = nil
        }
    }
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束

    @ViewBuilder
    private var alternateContactContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if state.isDepartmentFeatureEnabled {
                contentTabs
            }

            if state.isDepartmentFeatureEnabled && activeContentTab == .organization {
                organizationSection
            } else {
                contactSearchSection
            }
        }
    }

    private var contentTabs: some View { ContactContentTabs(selection: $activeContentTab) }

    private var organizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("组织架构")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
                state.enterpriseMembershipStore.observe(\.current.role) { role in
                    state.organizationDirectoryStore.observe({ state.canManageOrganizationDepartments(in: $0, role: role) }) { canManage in
                        if canManage {
                            Button {
                                showingDepartmentManagement = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(IMColor.brand)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(.white.opacity(0.88)))
                                    .overlay(Circle().stroke(IMColor.brand.opacity(0.12), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("organization_manage_button")
                            .accessibilityLabel("部门管理")
                        }
                    }
                }
                // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
                // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
            }
            OrganizationDirectoryView { department in
                selectedOrganizationDepartment = department
            }
        }
    }

    private var contactSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索联系人")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(IMColor.ink)
            if trimmedContactSearchDraft.isEmpty && appliedQuery.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "输入关键词搜索", subtitle: "支持姓名、用户ID或拼音。")
            } else if isContactSearchSettling {
                RemoteLoadingStateView(title: "正在搜索", subtitle: "输入结束后会显示匹配结果。")
            } else if displayedContactSearchResults.isEmpty {
                EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有联系人", subtitle: "换个关键词再试。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(displayedContactSearchResults) { row in
                        Button {
                            selectedUser = row.user
                        } label: {
                            ContactDirectoryRow(row: row)
                                .background(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(.white.opacity(0.88))
                                        .shadow(color: IMColor.brand.opacity(0.05), radius: 10, y: 6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(.white.opacity(0.70), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("contact_search_result_\(row.user.id)")
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
            }
        }
    }

    private var contactListTitle: some View {
        HStack {
            Text("联系人")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(IMColor.ink)
            Spacer()
            Button {
                showingFindUser = true
            } label: {
                Label("添加好友", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(IMColor.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(IMColor.brand.opacity(0.10)))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("contacts_add_friend_button")
        }
    }

    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_BEGIN
    private func contactListStatus(isInitialLoading: Bool) -> ContactDirectoryStatus { // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        let sync = observedContactsSync ?? state.contactStore.contactsSyncStatus
        if (isInitialLoading || sync.isSyncing) // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            && state.contacts.isEmpty && appliedQuery.isEmpty {
            return .loading
        }
        if let error = sync.errorMessage, appliedQuery.isEmpty {
            return .failed(error)
        }
        return .empty
    }
    // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110_END

    @ViewBuilder
    private func contactStatusView(_ status: ContactDirectoryStatus) -> some View {
        switch status {
        case .loading:
            RemoteLoadingStateView(title: "正在同步通讯录", subtitle: "正在拉取好友、群组和黑名单数据。")
        case .failed(let error):
            EmptyStateView(symbol: "wifi.exclamationmark", title: "通讯录同步失败", subtitle: error)
            PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                state.retryContactsSync()
            }
        case .empty:
            EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有联系人", subtitle: "换个关键词再试。")
        }
    }

    private func contactInitial(forSortKey key: String) -> String {
        guard let first = key.utf8.first, (65...90).contains(first) else { return "#" }
        return String(UnicodeScalar(first))
    }

    private func contactSortKey(_ displayName: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "#" }
        return name
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased() ?? name.uppercased()
    }

    private func contactGroupsSignature() -> String {
        var hasher = Hasher()
        hasher.combine(appliedQuery)
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_PRESENTATION_SIGNATURE - 修改开始：通讯录展示缓存只在认证/部门展示源变化时失效
        hasher.combine(state.certificationPresentationRevision)
        hasher.combine(state.isDepartmentFeatureEnabled)
        if state.isDepartmentFeatureEnabled {
            for (departmentID, members) in state.organizationDirectoryStore.snapshot.membersByDepartment.sorted(by: { $0.key < $1.key }) {
                hasher.combine(departmentID)
                hasher.combine(members.count)
                for member in members {
                    hasher.combine(member.id)
                    hasher.combine(member.userID)
                    hasher.combine(member.username)
                    hasher.combine(member.department)
                    hasher.combine(member.departmentPathNames)
                }
            }
        }
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_PRESENTATION_SIGNATURE - 修改结束：通讯录展示缓存只在认证/部门展示源变化时失效
        hasher.combine(state.contacts.count)
        state.contactRemarks.sorted(by: { $0.key < $1.key }).forEach { key, value in
            hasher.combine(key)
            hasher.combine(value)
        }
        state.contacts.forEach { user in
            hasher.combine(user.id)
            hasher.combine(user.userID)
            hasher.combine(user.username)
            hasher.combine(user.name)
            hasher.combine(user.title)
            hasher.combine(user.department)
            hasher.combine(user.departmentPathNames)
            hasher.combine(user.phone)
            hasher.combine(user.email)
            hasher.combine(user.status)
            hasher.combine(user.enterprise)
            hasher.combine(user.avatarURL)
            hasher.combine(user.avatarVersion)
            hasher.combine(user.avatarUpdatedAt)
            hasher.combine(user.badges)
        }
        return String(hasher.finalize())
    }

    private func contactDisplayNameMatches(_ name: String, query: String) -> Bool {
        let needle = IMUserSearchMatcher.normalized(query)
        guard !needle.isEmpty else { return true }
        return [name, name.applyingTransform(.toLatin, reverse: false) ?? name]
            .map(IMUserSearchMatcher.normalized)
            .contains { $0.contains(needle) }
    }

    // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_PREFETCH_HELPER - 修改开始：通讯录认证资料列表级预取，避免每个联系人行滚动出现时单独触发
    private func prefetchContactDirectoryCertifications(in groups: [ContactDirectoryGroup]) {
        let exactUIDs = groups.flatMap { group in
            group.rows.map { $0.user.id }
        }
        state.ensureCertificationPresentations(
            forExactUIDs: exactUIDs
        )
    }
    // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_PREFETCH_HELPER - 修改结束：通讯录认证资料列表级预取，避免每个联系人行滚动出现时单独触发

    private func contactLetterSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs < rhs
    }

    private func scheduleContactGroupsRebuild() {
        // TabView keeps this view mounted. Sync notifications can still arrive
        // after leaving it, but the directory can rebuild when it appears again.
        guard isDirectoryVisible else { return }
        if isDirectoryScrolling {
            needsDirectoryRebuild = true
            return
        }
        contactGroupsRebuildTask?.cancel()
        contactGroupsRebuildTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, isDirectoryVisible else { return }
            contactGroupsRebuildTask = nil
            if isDirectoryScrolling {
                needsDirectoryRebuild = true
            } else {
                rebuildContactGroupsIfNeeded()
            }
        }
    }

    private func directoryScrollChanged(_ isScrolling: Bool) {
        isDirectoryScrolling = isScrolling
        state.isContactDirectoryUserInteracting = isScrolling
        if !isScrolling {
            if needsGroupCountRefresh { refreshProjectedGroupCountCache() }
            if needsDirectoryRebuild {
                needsDirectoryRebuild = false
                scheduleContactGroupsRebuild()
            }
        }
    }

    private func applyContactSearchQuery(_ rawQuery: String) {
        let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery != appliedQuery else { return }
        contactGroupsRebuildTask?.cancel()
        contactGroupsRebuildTask = nil
        appliedQuery = normalizedQuery
        rebuildContactGroups()
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

import PhotosUI
import SwiftUI

func contactAuthoritativeUserNumber(userID: String) -> String? {
    let normalized = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

func accessibilityContactUserNumber(_ userID: String) -> String? {
    contactAuthoritativeUserNumber(userID: userID).map { "用户编号 \($0)" }
}

enum OtherUserAvatarPreviewPolicy {
    static func source(
        for user: IMUser,
        isSelf: Bool,
        isCancelled: Bool
    ) -> String? {
        guard !isSelf, !isCancelled else { return nil }
        let source = user.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              TenantRelativeImageURLResolver.request(source, routeContext: nil) != nil else {
            return nil
        }
        let normalizedSource = source
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .lowercased()
        let normalizedVersion = user.avatarVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let placeholderMarkers = [
            "/static/avatars/default-users/",
            "/static/avatars/default-users-v2/",
            "/avatars/user-default-avatar",
            "/avatars/default-user-avatar",
            "/avatars/user-cancelled-gray.svg"
        ]
        let isSystemPlaceholder = placeholderMarkers.contains { normalizedSource.contains($0) }
            || normalizedVersion.hasPrefix("default-user-avatar-")
            || normalizedVersion.hasPrefix("default-avatar-v2:")
        return isSystemPlaceholder ? nil : source
    }
}

// JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ROUTE_MODEL - 修改开始：通讯录/群列表进入聊天使用一次性 route，避免空 destination
private struct ContactsConversationRoute: Identifiable, Hashable {
    let id = UUID()
    let conversationID: String

    init(id conversationID: String) {
        self.conversationID = conversationID
    }
}
// JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ROUTE_MODEL - 修改结束

private enum ContactContentTab: String, CaseIterable, Identifiable {
    case contacts
    case organization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contacts: "联系人"
        case .organization: "组织架构"
        }
    }

    var symbol: String {
        switch self {
        case .contacts: "person.2.fill"
        case .organization: "building.2.fill"
        }
    }
}

// JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_MODEL - 修改开始：通讯录行预渲染模型，滚动时不再反复读取全局状态计算展示字段
private struct ContactDirectoryGroup: Identifiable, Equatable {
    let letter: String
    let rows: [ContactDirectoryRowPresentation]

    var id: String { letter }
}

private struct ContactDirectoryRowPresentation: Identifiable, Equatable {
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
private func contactDirectoryRowPresentation(
    for user: IMUser,
    state: AppState,
    includeDepartmentSummary: Bool,
    accessibilityPrefix: String = "联系人"
) -> ContactDirectoryRowPresentation {
    let displayName = state.contactDirectoryDisplayName(for: user)
    return ContactDirectoryRowPresentation(
        user: user,
        displayName: displayName,
        userNumber: contactAuthoritativeUserNumber(userID: user.userID),
        departmentSummary: includeDepartmentSummary ? state.departmentSummary(for: user) : nil,
        certification: state.certificationPresentation(forExactUID: user.id),
        accessibilityPrefix: accessibilityPrefix
    )
}
// JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_ROW_PRESENTATION_MODEL - 修改结束：通讯录行预渲染模型，滚动时不再反复读取全局状态计算展示字段

struct ContactsView: View {
    @EnvironmentObject private var state: AppState
    @State private var appliedQuery = ""
    @State private var contactSearchDraft = ""
    @State private var selectedRoute: ContactRoute?
    @State private var selectedUser: IMUser?
    // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_CONTACTS_ROUTE_STATE - 修改开始：联系人页聊天跳转改为稳定 item route
    @State private var selectedConversationRoute: ContactsConversationRoute?
    // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CONTACTS_ROUTE_STATE - 修改结束
    @State private var activeContentTab: ContactContentTab = .contacts
    @State private var cachedContactGroups: [ContactDirectoryGroup] = []
    @State private var cachedContactGroupsSignature = ""
    @State private var showingDepartmentManagement = false
    @State private var selectedOrganizationDepartment: RemoteDepartmentNode?
    @State private var isContactSearchEditing = false
    @State private var contactGroupsRebuildTask: Task<Void, Never>?
    @State private var groupDirectoryRefreshTask: Task<Void, Never>?
    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：伙伴 Tab 入口计数缓存与自动刷新节流，减少切换卡顿
    @State private var groupDirectoryRefreshGeneration = 0
    @State private var lastAutomaticGroupDirectoryRefreshAt: Date?
    @State private var cachedPendingFriendRequestCount = 0
    @State private var cachedProjectedGroupCount = 0
    @State private var cachedBlacklistCount = 0
    private let automaticGroupDirectoryRefreshInterval: TimeInterval = 45
    // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
    private let searchResultLimit = 20

    private var projectedGroups: [GroupInfo] {
        ContactStore.projectedGroupDirectory(
            authoritativeGroups: state.groups,
            conversations: state.conversations
        )
    }

    private var displayedContactGroups: [ContactDirectoryGroup] {
        cachedContactGroups
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
                includeDepartmentSummary: shouldShowDepartment
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
        cachedContactGroups = renderContactGroups()
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_BATCH_PREFETCH - 修改开始：通讯录认证展示改为列表级批量预取，避免每行滚动出现时触发检查
        prefetchContactDirectoryCertifications(in: cachedContactGroups)
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_BATCH_PREFETCH - 修改结束：通讯录认证展示改为列表级批量预取，避免每行滚动出现时触发检查
    }

    private func rebuildContactGroupsIfNeeded() {
        let signature = contactGroupsSignature()
        guard signature != cachedContactGroupsSignature else { return }
        cachedContactGroupsSignature = signature
        cachedContactGroups = renderContactGroups()
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_CERTIFICATION_BATCH_PREFETCH_IF_NEEDED - 修改开始：缓存变化后统一预取通讯录认证展示，滚动时行视图保持轻量
        prefetchContactDirectoryCertifications(in: cachedContactGroups)
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_CERTIFICATION_BATCH_PREFETCH_IF_NEEDED - 修改结束：缓存变化后统一预取通讯录认证展示，滚动时行视图保持轻量
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    PinnedSearchHeader {
                        DebouncedContactsSearchField(
                            placeholder: "搜索联系人、用户ID或拼音",
                            onDraftChange: { contactSearchDraft = $0 },
                            onEditingChange: { isContactSearchEditing = $0 },
                            onQueryChange: applyContactSearchQuery
                        )
                    }
                    contactContent
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .overlay(alignment: .top) {
            PinnedSearchTopMask()
        }
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
            UserProfileView(user: user, onOpenConversation: { conversationID in
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
            ChatView(conversationID: route.conversationID)
        }
        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CONTACTS_DESTINATION - 修改结束
        .onAppear {
            rebuildContactGroupsIfNeeded()
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：切回伙伴页时复用缓存计数，自动群目录刷新短时间内只触发一次
            refreshContactQuickEntryCaches()
            startGroupDirectoryRefreshIfNeeded()
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        }
        .onDisappear {
            contactGroupsRebuildTask?.cancel()
            contactGroupsRebuildTask = nil
            // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：取消隐藏页刷新时递增 generation，避免旧任务回写任务状态
            groupDirectoryRefreshGeneration += 1
            groupDirectoryRefreshTask?.cancel()
            groupDirectoryRefreshTask = nil
            // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        }
        .onChangeCompat(of: state.contacts) { _, _ in
            scheduleContactGroupsRebuild()
        }
        .onChangeCompat(of: state.contactRemarks) { _, _ in
            scheduleContactGroupsRebuild()
        }
        .onChangeCompat(of: state.isDepartmentFeatureEnabled) { _, isEnabled in
            if !isEnabled {
                activeContentTab = .contacts
            }
            // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_DEPARTMENT_CACHE_REFRESH - 修改开始：部门展示开关变化时只重建通讯录展示缓存
            scheduleContactGroupsRebuild()
            // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_DEPARTMENT_CACHE_REFRESH - 修改结束：部门展示开关变化时只重建通讯录展示缓存
        }
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_PRESENTATION_CACHE_REFRESH - 修改开始：认证/部门数据变化时合并刷新通讯录展示缓存，避免滚动中逐行查状态
        .onChangeCompat(of: state.certificationPresentationRevision) { _, _ in
            scheduleContactGroupsRebuild()
        }
        .onChangeCompat(of: state.organizationMembersByDepartmentID) { _, _ in
            scheduleContactGroupsRebuild()
        }
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_PRESENTATION_CACHE_REFRESH - 修改结束：认证/部门数据变化时合并刷新通讯录展示缓存，避免滚动中逐行查状态
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：入口卡片计数只在对应数据源变化时重算
        .onReceive(state.contactStore.$friendRequests) { _ in
            refreshPendingFriendRequestCountCache()
        }
        .onReceive(state.contactStore.$groups) { _ in
            refreshProjectedGroupCountCache()
        }
        .onReceive(state.conversationStore.$conversations) { _ in
            refreshProjectedGroupCountCache()
        }
        .onReceive(state.contactStore.$blacklist) { _ in
            refreshBlacklistCountCache()
        }
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        .sheet(isPresented: $showingDepartmentManagement) {
            DepartmentManagementSheet()
                .environmentObject(state)
                .presentationDetentsCompat([.large])
                .presentationDragIndicatorCompat(.visible)
        }
    }

    private var pendingFriendRequestSubtitle: String {
        // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：使用缓存的新朋友数量，避免 body 中重复 filter
        let visibleCount = UnreadBadgeFormatter.text(cachedPendingFriendRequestCount) ?? "0"
        // JHT_MOD_END MAIN_TAB_SWITCH_PERF_20260912 - 修改结束
        return "\(visibleCount) 个待处理"
    }

    private var quickEntries: some View {
        HStack(spacing: 10) {
            Button {
                selectedRoute = .newFriends
            } label: {
                ContactEntryCard(symbol: "person.badge.plus", title: "新朋友", subtitle: pendingFriendRequestSubtitle, color: IMColor.brand, badgeCount: cachedPendingFriendRequestCount)
            }
            .accessibilityIdentifier("contacts_entry_new_friends")
            .accessibilityLabel("新朋友")
            Button {
                selectedRoute = .groupList
            } label: {
                ContactEntryCard(symbol: "person.3.fill", title: "群列表", subtitle: "\(cachedProjectedGroupCount) 个群聊", color: IMColor.violet)
            }
            .accessibilityIdentifier("contacts_entry_group_list")
            .accessibilityLabel("群列表")
            Button {
                selectedRoute = .blacklist
            } label: {
                ContactEntryCard(symbol: "hand.raised.fill", title: "黑名单", subtitle: "\(cachedBlacklistCount) 个账号", color: IMColor.danger)
            }
            .accessibilityIdentifier("contacts_entry_blacklist")
            .accessibilityLabel("黑名单")
        }
        .buttonStyle(.plain)
    }

    // JHT_MOD_BEGIN MAIN_TAB_SWITCH_PERF_20260912 - 修改开始：伙伴 Tab 自动刷新节流与入口计数缓存
    private func refreshContactQuickEntryCaches() {
        refreshPendingFriendRequestCountCache()
        refreshProjectedGroupCountCache()
        refreshBlacklistCountCache()
    }

    private func refreshPendingFriendRequestCountCache() {
        let nextValue = state.pendingFriendRequestCount
        guard cachedPendingFriendRequestCount != nextValue else { return }
        cachedPendingFriendRequestCount = nextValue
    }

    private func refreshProjectedGroupCountCache() {
        let nextValue = projectedGroups.count
        guard cachedProjectedGroupCount != nextValue else { return }
        cachedProjectedGroupCount = nextValue
    }

    private func refreshBlacklistCountCache() {
        let nextValue = state.blacklist.count
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
    private var contactContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if state.isDepartmentFeatureEnabled {
                contentTabs
            }

            if state.isDepartmentFeatureEnabled && activeContentTab == .organization {
                organizationSection
            } else if isContactSearchActive {
                contactSearchSection
            } else {
                quickEntries
                contactSection
            }
        }
    }

    private var contentTabs: some View {
        HStack(spacing: 6) {
            ForEach(ContactContentTab.allCases) { tab in
                let selected = activeContentTab == tab
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                        activeContentTab = tab
                    }
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(selected ? .white : IMColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selected ? IMColor.brand : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("contacts_tab_\(tab.rawValue)")
                .accessibilityLabel(tab.title)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.70), lineWidth: 1)
        )
    }

    private var organizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("组织架构")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                if state.canManageOrganizationDepartments {
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

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("联系人")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(IMColor.ink)
            if (state.isInitialDataLoading && !state.hasLoadedRemoteSnapshot && state.contacts.isEmpty && appliedQuery.isEmpty)
                || (state.isContactsSyncing && state.contacts.isEmpty && appliedQuery.isEmpty) {
                RemoteLoadingStateView(
                    title: "正在同步通讯录",
                    subtitle: "正在拉取好友、群组和黑名单数据。"
                )
            } else if let contactsSyncError = state.contactsSyncErrorMessage, displayedContactGroups.isEmpty, appliedQuery.isEmpty {
                EmptyStateView(symbol: "wifi.exclamationmark", title: "通讯录同步失败", subtitle: contactsSyncError)
                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                    state.retryContactsSync()
                }
            } else if displayedContactGroups.isEmpty {
                EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有联系人", subtitle: "换个关键词再试。")
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(displayedContactGroups, id: \.letter) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.letter)
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .padding(.horizontal, 6)
                            LazyVStack(spacing: 0) {
                                ForEach(group.rows) { row in
                                    let isLastRow = group.rows.last?.id == row.id
                                    Button {
                                        selectedUser = row.user
                                    } label: {
                                        ContactDirectoryRow(row: row)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                    .accessibilityIdentifier("contact_row_\(row.user.id)")
                                    .accessibilityLabel(row.accessibilityLabel)
                                    if !isLastRow {
                                        Divider()
                                            .padding(.leading, 62)
                                            .opacity(0.72)
                                    }
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(.white.opacity(0.88))
                                    .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(.white.opacity(0.72), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    private func contactInitial(forSortKey key: String) -> String {
        guard let first = key.unicodeScalars.first else { return "#" }
        let letter = String(Character(first)).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
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
            for (departmentID, members) in state.organizationMembersByDepartmentID.sorted(by: { $0.key < $1.key }) {
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
        contactGroupsRebuildTask?.cancel()
        contactGroupsRebuildTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            rebuildContactGroupsIfNeeded()
            contactGroupsRebuildTask = nil
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
}

private struct DebouncedContactsSearchField: View {
    let placeholder: String
    let onDraftChange: (String) -> Void
    let onEditingChange: (Bool) -> Void
    let onQueryChange: (String) -> Void
    @State private var text = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IMColor.muted)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cancelSearch()
                    } else {
                        applyQueryNow(text)
                    }
                }
                .imReadableInputText()
            if !text.isEmpty {
                Button {
                    text = ""
                    onDraftChange("")
                    onQueryChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(hex: 0xB7BED0))
                }
                .buttonStyle(.plain)
            }
            Button {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cancelSearch()
                } else {
                    applyQueryNow(text)
                }
            } label: {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isFocused ? "取消" : "搜索")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
        )
        .onChangeCompat(of: text) { _, newText in
            onDraftChange(newText)
            scheduleQueryChange(newText)
            publishEditingState()
        }
        .onChangeCompat(of: isFocused) { _, _ in
            publishEditingState()
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    private func scheduleQueryChange(_ rawQuery: String) {
        debounceTask?.cancel()
        let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            onQueryChange("")
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            onQueryChange(normalizedQuery)
        }
    }

    private func applyQueryNow(_ rawQuery: String) {
        debounceTask?.cancel()
        onQueryChange(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cancelSearch() {
        debounceTask?.cancel()
        text = ""
        isFocused = false
        onDraftChange("")
        onQueryChange("")
        onEditingChange(false)
    }

    private func publishEditingState() {
        onEditingChange(isFocused || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private enum ContactRoute: String, Identifiable, Hashable {
    case newFriends
    case groupList
    case blacklist

    var id: String { rawValue }
}

private struct ContactEntryCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let color: Color
    var badgeCount: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(color.opacity(0.12)))
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let badgeText = UnreadBadgeFormatter.text(badgeCount) {
                Text(badgeText)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, badgeText.count > 1 ? 3 : 0)
                    .background(Capsule().fill(IMColor.danger))
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                    .shadow(color: IMColor.danger.opacity(0.22), radius: 5, y: 2)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    .accessibilityLabel("\(badgeText) 个待处理好友申请")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.9))
                .shadow(color: color.opacity(0.10), radius: 16, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct OrganizationDirectoryView: View {
    @EnvironmentObject private var state: AppState
    let onShowMembers: (RemoteDepartmentNode) -> Void

    var body: some View {
        if state.isOrganizationSyncing && state.organizationTree == nil {
            RemoteLoadingStateView(
                title: "正在同步组织架构",
                subtitle: "正在拉取部门和成员数据。"
            )
        } else if let error = state.organizationSyncErrorMessage, state.organizationTree == nil {
            VStack(alignment: .leading, spacing: 12) {
                EmptyStateView(symbol: "wifi.exclamationmark", title: "组织架构同步失败", subtitle: error)
                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                    state.retryContactsSync()
                }
            }
        } else if let tree = state.organizationTree {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = state.organizationSyncErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .black))
                        Text(error)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(2)
                    }
                    .foregroundStyle(IMColor.warning)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider().opacity(0.72)
                }

                if let root = tree.root {
                    OrganizationDepartmentNodeView(node: root, level: 0, initiallyExpanded: true, onShowMembers: onShowMembers)
                } else if tree.items.isEmpty {
                    EmptyStateView(symbol: "building.2.crop.circle", title: "暂无组织架构", subtitle: "当前企业还没有部门数据。")
                        .padding(.vertical, 22)
                } else {
                    ForEach(tree.items) { node in
                        OrganizationDepartmentNodeView(node: node, level: 0, initiallyExpanded: true, onShowMembers: onShowMembers)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            )
        } else {
            EmptyStateView(symbol: "building.2.crop.circle", title: "暂无组织架构", subtitle: "当前企业还没有部门数据。")
        }
    }
}

private struct OrganizationDepartmentNodeView: View {
    @EnvironmentObject private var state: AppState
    let node: RemoteDepartmentNode
    let level: Int
    let onShowMembers: (RemoteDepartmentNode) -> Void
    @State private var isExpanded: Bool

    init(
        node: RemoteDepartmentNode,
        level: Int,
        initiallyExpanded: Bool = true,
        onShowMembers: @escaping (RemoteDepartmentNode) -> Void
    ) {
        self.node = node
        self.level = level
        self.onShowMembers = onShowMembers
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var members: [IMUser] {
        state.organizationMembers(for: node.departmentID)
    }

    private var displayName: String {
        let trimmed = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "公司" : trimmed
    }

    private var hasChildren: Bool {
        !node.children.isEmpty
    }

    private var displayMemberCount: Int {
        node.memberCount > 0 ? node.memberCount : members.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if hasChildren {
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        departmentLabel
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("organization_department_\(node.departmentID)")
                    .accessibilityLabel("部门 \(displayName)")
                } else {
                    departmentLabel
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("organization_department_\(node.departmentID)")
                        .accessibilityLabel("部门 \(displayName)")
                }

                Button {
                    onShowMembers(node)
                } label: {
                    Text("查看成员")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(IMColor.page.opacity(0.92)))
                        .overlay(Capsule().stroke(IMColor.brand.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("organization_view_members_\(node.departmentID)")
                .accessibilityLabel("查看 \(displayName) 成员")
            }
            .padding(.leading, CGFloat(level) * 18 + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 11)

            if isExpanded {
                ForEach(node.children) { child in
                    OrganizationDepartmentNodeView(node: child, level: level + 1, initiallyExpanded: true, onShowMembers: onShowMembers)
                }
            }
        }
    }

    private var departmentLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: hasChildren ? (isExpanded ? "chevron.down" : "chevron.right") : "circle.fill")
                .font(.system(size: hasChildren ? 11 : 6, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 18)
            Image(systemName: node.isVirtual ? "building.2.fill" : "folder.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(node.isVirtual ? IMColor.brand : IMColor.violet)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Text(displayMemberCount > 0 ? "\(displayMemberCount) 人" : "暂无成员")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct OrganizationDepartmentMembersView: View {
    @EnvironmentObject private var state: AppState
    let department: RemoteDepartmentNode
    @State private var selectedUser: IMUser?
    // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ORG_ROUTE_STATE - 修改开始：组织成员页聊天跳转改为稳定 item route
    @State private var selectedConversationRoute: ContactsConversationRoute?
    // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ORG_ROUTE_STATE - 修改结束

    private var members: [IMUser] {
        state.organizationMembers(for: department.departmentID)
    }

    private var displayName: String {
        let trimmed = department.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "公司" : trimmed
    }

    private var displayCount: Int {
        department.memberCount > 0 ? department.memberCount : members.count
    }

    private var pathText: String {
        let names = department.departmentPathNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return displayName }
        return names.joined(separator: " / ")
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    memberList
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestinationCompat(item: $selectedUser) { user in
            UserProfileView(user: user, onOpenConversation: { conversationID in
                // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ORG_PROFILE_ROUTE - 修改开始：避免 Bool+Optional 跳转生成空聊天页
                selectedConversationRoute = ContactsConversationRoute(id: conversationID)
                // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ORG_PROFILE_ROUTE - 修改结束
            })
        }
        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_ORG_DESTINATION - 修改开始：聊天页目标由 route 直接携带
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            ChatView(conversationID: route.conversationID)
        }
        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_ORG_DESTINATION - 修改结束
        .toolbarTabBarHiddenCompat()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: department.isVirtual ? "building.2.fill" : "folder.fill")
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(department.isVirtual ? IMColor.brand : IMColor.violet)
                .frame(width: 46, height: 46)
                .background(Circle().fill((department.isVirtual ? IMColor.brand : IMColor.violet).opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                Text(pathText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(displayCount) 人")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.brand)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(IMColor.brand.opacity(0.10)))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.9))
                .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var memberList: some View {
        if state.isOrganizationSyncing && members.isEmpty {
            RemoteLoadingStateView(
                title: "正在同步成员",
                subtitle: "正在拉取部门成员数据。"
            )
        } else if members.isEmpty {
            EmptyStateView(symbol: "person.2.slash", title: "暂无成员", subtitle: "该部门当前没有成员。")
                .padding(.vertical, 8)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(members) { user in
                    let isLastRow = members.last?.id == user.id
                    // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_ORGANIZATION_MEMBER_ROW_PRESENTATION - 修改开始：组织成员行复用预计算展示模型，减少滚动时读取全局状态
                    let row = contactDirectoryRowPresentation(
                        for: user,
                        state: state,
                        includeDepartmentSummary: state.isDepartmentFeatureEnabled,
                        accessibilityPrefix: "成员"
                    )
                    // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_ORGANIZATION_MEMBER_ROW_PRESENTATION - 修改结束：组织成员行复用预计算展示模型，减少滚动时读取全局状态
                    Button {
                        selectedUser = user
                    } label: {
                        ContactDirectoryRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("organization_member_\(user.id)")
                    .accessibilityLabel(row.accessibilityLabel)
                    if !isLastRow {
                        Divider()
                            .padding(.leading, 62)
                            .opacity(0.72)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.88))
                    .shadow(color: IMColor.brand.opacity(0.06), radius: 14, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            )
        }
    }
}

private struct DepartmentManagementSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDepartmentID = "company"
    @State private var departmentNameDraft = ""
    @State private var childDepartmentName = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingMemberInvite = false

    private var departmentNodes: [RemoteDepartmentNode] {
        var nodes: [RemoteDepartmentNode] = []
        func append(_ node: RemoteDepartmentNode) {
            nodes.append(node)
            node.children.forEach(append)
        }
        if let root = state.organizationTree?.root {
            append(root)
        } else {
            state.organizationTree?.items.forEach(append)
        }
        return nodes
    }

    private var departmentTreeRevision: String {
        departmentNodes
            .map { "\($0.departmentID):\($0.parentDepartmentID):\($0.name):\($0.memberCount)" }
            .joined(separator: "|")
    }

    private var selectedDepartment: RemoteDepartmentNode? {
        let normalized = normalizedDepartmentID(selectedDepartmentID)
        return departmentNodes.first { normalizedDepartmentID($0.departmentID) == normalized }
    }

    private var selectedMembers: [IMUser] {
        state.organizationMembers(for: selectedDepartmentID)
    }

    private var isCompanySelected: Bool {
        normalizedDepartmentID(selectedDepartmentID) == "company" || selectedDepartment?.isVirtual == true
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(symbol: "building.2.fill", title: "部门管理", subtitle: "编辑组织架构和部门成员。", showsCloseButton: true)
                departmentChooser
                selectedDepartmentPanel
                memberPanel
            }
            .padding(20)
        }
        .background(IMColor.page.ignoresSafeArea())
        .onAppear {
            ensureSelectedDepartmentExists()
            syncDepartmentDraft()
        }
        .onChangeCompat(of: selectedDepartmentID) { _, _ in
            syncDepartmentDraft()
        }
        .onChangeCompat(of: departmentTreeRevision) { _, _ in
            ensureSelectedDepartmentExists()
            syncDepartmentDraft()
        }
        .sheet(isPresented: $showingMemberInvite) {
            DepartmentMemberInviteSheet(
                departmentID: selectedDepartmentID,
                departmentName: displayDepartmentName(selectedDepartment),
                currentMemberIDs: Set(selectedMembers.map { $0.id })
            )
            .environmentObject(state)
            .presentationDetentsCompat([.large])
            .presentationDragIndicatorCompat(.visible)
        }
        .confirmationDialog("删除部门", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除并迁移成员", role: .destructive) {
                Task {
                    let deletedID = selectedDepartmentID
                    selectedDepartmentID = "company"
                    _ = await state.deleteOrganizationDepartment(departmentID: deletedID)
                }
            }
            Button("取消", role: .cancel) {
                showingDeleteConfirmation = false
            }
        } message: {
            Text("该部门成员和子部门会自动迁移到上一级部门。")
        }
    }

    private var departmentChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("部门")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.muted)
            if departmentNodes.isEmpty {
                EmptyStateView(symbol: "building.2.crop.circle", title: "暂无组织架构", subtitle: "可先刷新后再管理。")
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(departmentNodes) { node in
                            departmentChoiceButton(node)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var selectedDepartmentPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isCompanySelected ? "building.2.fill" : "folder.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(isCompanySelected ? IMColor.brand : IMColor.violet)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill((isCompanySelected ? IMColor.brand : IMColor.violet).opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayDepartmentName(selectedDepartment))
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    Text("\(selectedMembers.count) 人")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
            }

            if !isCompanySelected {
                FormInput(title: "部门名称", placeholder: "输入部门名称", text: $departmentNameDraft)
                PrimaryButton(title: state.isOrganizationManagementSaving ? "保存中..." : "保存部门", systemImage: "checkmark.circle.fill", disabled: state.isOrganizationManagementSaving) {
                    Task {
                        _ = await state.updateOrganizationDepartment(departmentID: selectedDepartmentID, parentDepartmentID: nil, name: departmentNameDraft)
                    }
                }
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("删除部门", systemImage: "trash.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.danger.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(state.isOrganizationManagementSaving)
            }

            FormInput(title: isCompanySelected ? "新建顶级部门" : "新建子部门", placeholder: "输入部门名称", text: $childDepartmentName)
            PrimaryButton(title: state.isOrganizationManagementSaving ? "创建中..." : "添加部门", systemImage: "plus.circle.fill", disabled: state.isOrganizationManagementSaving || childDepartmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task {
                    if await state.createOrganizationDepartment(parentDepartmentID: selectedDepartmentID, name: childDepartmentName) {
                        childDepartmentName = ""
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
    }

    private var memberPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("成员")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Text("\(selectedMembers.count)")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted)
                if !isCompanySelected {
                    Button {
                        guard !state.isOrganizationManagementSaving else { return }
                        showingMemberInvite = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(IMColor.brand))
                            .shadow(color: IMColor.brand.opacity(0.20), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isOrganizationManagementSaving)
                    .opacity(state.isOrganizationManagementSaving ? 0.45 : 1)
                    .accessibilityLabel("邀请成员")
                }
            }

            if selectedMembers.isEmpty {
                EmptyStateView(symbol: "person.2.slash", title: "暂无成员", subtitle: isCompanySelected ? "无部门成员会显示在公司下。" : "可从已同步成员中加入。")
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selectedMembers.enumerated()), id: \.element.id) { index, user in
                        memberRow(user)
                        if index < selectedMembers.count - 1 {
                            Divider().padding(.leading, 58).opacity(0.7)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
            }
        }
    }

    private func departmentChoiceButton(_ node: RemoteDepartmentNode) -> some View {
        let normalizedID = normalizedDepartmentID(node.departmentID)
        let selected = normalizedDepartmentID(selectedDepartmentID) == normalizedID
        return Button {
            selectedDepartmentID = normalizedID
        } label: {
            HStack(spacing: 7) {
                Image(systemName: node.isVirtual ? "building.2.fill" : "folder.fill")
                    .font(.system(size: 12, weight: .black))
                Text(displayDepartmentName(node))
                    .font(.system(size: 13, weight: .black))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .white : IMColor.ink)
            .padding(.leading, 12 + CGFloat(max(node.depth, 0)) * 6)
            .padding(.trailing, 12)
            .frame(height: 36)
            .background(Capsule().fill(selected ? IMColor.brand : .white.opacity(0.86)))
            .overlay(Capsule().stroke(selected ? IMColor.brand.opacity(0.2) : .white.opacity(0.72), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func memberRow(_ user: IMUser) -> some View {
        let displayName = state.remarkPreferredDisplayName(for: user)
        return HStack(spacing: 10) {
            AvatarView(name: displayName, seed: user.avatarSeed, size: 42, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
            VStack(alignment: .leading, spacing: 3) {
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
                Text(user.title.isEmpty ? user.id : user.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            if !isCompanySelected {
                Button(role: .destructive) {
                    Task {
                        _ = await state.removeOrganizationMember(departmentID: selectedDepartmentID, userID: user.id)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(IMColor.danger)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(state.isOrganizationManagementSaving)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func ensureSelectedDepartmentExists() {
        guard !departmentNodes.isEmpty else {
            selectedDepartmentID = "company"
            return
        }
        let normalized = normalizedDepartmentID(selectedDepartmentID)
        if !departmentNodes.contains(where: { normalizedDepartmentID($0.departmentID) == normalized }) {
            selectedDepartmentID = normalizedDepartmentID(departmentNodes.first?.departmentID ?? "company")
        }
    }

    private func syncDepartmentDraft() {
        departmentNameDraft = isCompanySelected ? "" : displayDepartmentName(selectedDepartment)
    }

    private func displayDepartmentName(_ node: RemoteDepartmentNode?) -> String {
        let name = node?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "公司" : name
    }

    private func normalizedDepartmentID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "__company__" || trimmed == "__root__" {
            return "company"
        }
        return trimmed
    }
}

private struct DepartmentMemberInviteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let departmentID: String
    let departmentName: String
    let currentMemberIDs: Set<String>
    @State private var query = ""
    @State private var selectedUserID = ""
    @State private var isSubmitting = false

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetDepartmentName: String {
        let trimmed = departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "当前部门" : trimmed
    }

    private var candidateUsers: [IMUser] {
        let users = state.organizationManagementCandidateUsers.filter { user in
            normalizedQuery.isEmpty || IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: normalizedQuery
            )
        }
        return users.sorted {
            state.remarkPreferredDisplayName(for: $0)
                .localizedCaseInsensitiveCompare(state.remarkPreferredDisplayName(for: $1)) == .orderedAscending
        }
    }

    private var selectedUser: IMUser? {
        state.organizationManagementCandidateUsers.first { $0.id == selectedUserID }
    }

    private var selectedUserAlreadyInTarget: Bool {
        guard !selectedUserID.isEmpty else { return false }
        return currentMemberIDs.contains(selectedUserID)
    }

    private var confirmDisabled: Bool {
        selectedUserID.isEmpty || selectedUserAlreadyInTarget || isSubmitting || state.isOrganizationManagementSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                symbol: "person.crop.circle.badge.plus",
                title: "邀请成员",
                subtitle: "搜索企业用户，确认后将主部门变更为\(targetDepartmentName)。",
                showsCloseButton: true
            )
            SearchField(text: $query, placeholder: "搜索成员、用户ID或拼音")
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if candidateUsers.isEmpty {
                        EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有匹配成员", subtitle: "换个姓名、用户ID或拼音再试。")
                            .padding(.vertical, 12)
                    } else {
                        ForEach(candidateUsers) { user in
                            inviteCandidateRow(user)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            PrimaryButton(title: confirmButtonTitle, systemImage: "checkmark.circle.fill", disabled: confirmDisabled) {
                submit()
            }
        }
        .padding(18)
        .background(IMColor.page.ignoresSafeArea())
        .onChangeCompat(of: query) { _, _ in
            if let selectedUser, !candidateUsers.contains(where: { $0.id == selectedUser.id }) {
                selectedUserID = ""
            }
        }
    }

    private var confirmButtonTitle: String {
        if isSubmitting || state.isOrganizationManagementSaving {
            return "变更中..."
        }
        if selectedUserAlreadyInTarget {
            return "已在当前部门"
        }
        return selectedUserID.isEmpty ? "选择成员后确认" : "确认变更到当前部门"
    }

    private func inviteCandidateRow(_ user: IMUser) -> some View {
        let selected = selectedUserID == user.id
        let alreadyInTarget = currentMemberIDs.contains(user.id)
        let displayName = state.remarkPreferredDisplayName(for: user)
        return Button {
            guard !alreadyInTarget else { return }
            selectedUserID = selected ? "" : user.id
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                VStack(alignment: .leading, spacing: 5) {
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
                        font: .system(size: 11, weight: .semibold),
                        color: IMColor.muted
                    )
                    Label(userDepartmentText(user), systemImage: "building.2.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
                Spacer()
                if alreadyInTarget {
                    Text("已在当前部门")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.success)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Capsule().fill(IMColor.success.opacity(0.10)))
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(selected ? IMColor.brand : IMColor.muted.opacity(0.55))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? IMColor.brand.opacity(0.08) : .white.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? IMColor.brand.opacity(0.30) : .white.opacity(0.72), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("department_invite_candidate_\(user.id)")
        .accessibilityLabel(
            [
                "邀请候选人 \(displayName)，当前部门 \(userDepartmentText(user))",
                state.certificationPresentation(
                    forExactUID: user.id
                )?.accessibilityLabel
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
    }

    private func userDepartmentText(_ user: IMUser) -> String {
        state.departmentSummary(for: user, fullPath: true) ?? "公司"
    }

    private func submit() {
        guard !confirmDisabled else { return }
        let userID = selectedUserID
        isSubmitting = true
        Task {
            let ok = await state.addOrganizationMember(departmentID: departmentID, userID: userID)
            await MainActor.run {
                isSubmitting = false
                if ok {
                    dismiss()
                }
            }
        }
    }
}

private struct ContactDirectoryRow: View {
    let row: ContactDirectoryRowPresentation

    private var user: IMUser {
        row.user
    }

    private var displayName: String {
        row.displayName
    }

    var body: some View {
        // JHT_MOD_BEGIN CONTACT_LIST_SCROLL_PERF_BEGIN_ROW_USE_PRESENTATION - 修改开始：通讯录行只消费预计算展示模型，不再滚动时读取 AppState
        let certification = row.certification
        HStack(spacing: 12) {
            AvatarView(name: displayName, seed: user.avatarSeed, size: 44, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: certification)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: user.id,
                        compact: true,
                        presentation: certification,
                        usesProvidedPresentationOnly: true
                    )
                }
                if let userNumber = row.userNumber {
                    Text("用户编号：\(userNumber)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let department = row.departmentSummary {
                    Text(department)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted.opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        // JHT_MOD_END CONTACT_LIST_SCROLL_PERF_END_ROW_USE_PRESENTATION - 修改结束：通讯录行只消费预计算展示模型，不再滚动时读取 AppState
    }
}

struct ContactRow: View {
    @EnvironmentObject private var state: AppState

    let user: IMUser

    private var displayName: String {
        state.remarkPreferredDisplayName(for: user)
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: displayName, seed: user.avatarSeed, size: 48, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
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
                if let userNumber = contactAuthoritativeUserNumber(userID: user.userID) {
                    Text("用户编号：\(userNumber)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if user.isCancelledUser {
                    Text("已注销")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
        .plainCard(radius: 22)
    }
}

struct GroupListView: View {
    @EnvironmentObject private var state: AppState
    // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_GROUP_ROUTE_STATE - 修改开始：群列表聊天跳转改为稳定 item route
    @State private var selectedConversationRoute: ContactsConversationRoute?
    // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_GROUP_ROUTE_STATE - 修改结束
    @State private var showCreateGroupSheet = false
    @State private var cachedGroupSections: GroupListRenderSections = .empty
    @State private var hasGroupListCache = false
    @State private var groupDirectoryRefreshTask: Task<Void, Never>?

    private var groupSections: GroupListRenderSections {
        hasGroupListCache ? cachedGroupSections : buildGroupSections()
    }

    private var projectedGroups: [GroupInfo] {
        ContactStore.projectedGroupDirectory(
            authoritativeGroups: state.groups,
            conversations: state.conversations
        )
    }

    var body: some View {
        List {
            if state.canCreateGroupChat {
                Section {
                    Button {
                        showCreateGroupSheet = true
                    } label: {
                        GroupCreateEntryRow()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_list_create_group_button")
                    .accessibilityLabel("创建群聊")
                }
            }

            Section("我创建 / 管理") {
                ForEach(groupSections.managed) { item in
                    Button {
                        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_GROUP_MANAGED_ROUTE - 修改开始：每次点击群聊生成新的 route
                        selectedConversationRoute = ContactsConversationRoute(id: conversationID(for: item))
                        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_GROUP_MANAGED_ROUTE - 修改结束
                    } label: {
                        GroupListRow(group: item.group, conversation: item.conversation)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_list_row_\(item.group.id)")
                    .accessibilityLabel("群聊 \(item.group.name)")
                }
            }

            Section("我加入的") {
                ForEach(groupSections.joined) { item in
                    Button {
                        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_GROUP_JOINED_ROUTE - 修改开始：每次点击群聊生成新的 route
                        selectedConversationRoute = ContactsConversationRoute(id: conversationID(for: item))
                        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_GROUP_JOINED_ROUTE - 修改结束
                    } label: {
                        GroupListRow(group: item.group, conversation: item.conversation)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_list_row_\(item.group.id)")
                    .accessibilityLabel("群聊 \(item.group.name)")
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_GROUP_DESTINATION - 修改开始：群列表聊天页目标由 route 直接携带
        .navigationDestinationCompat(item: $selectedConversationRoute) { route in
            ChatView(conversationID: route.conversationID)
        }
        // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_GROUP_DESTINATION - 修改结束
        .onAppear {
            rebuildGroupListCache()
            projectedGroups.forEach { group in
                state.loadGroupDetailIfNeeded(groupID: group.id)
            }
            startGroupDirectoryRefresh()
        }
        .refreshable {
            _ = await state.refreshGroupDirectory(silent: false)
        }
        .onDisappear {
            groupDirectoryRefreshTask?.cancel()
            groupDirectoryRefreshTask = nil
        }
        .onChangeCompat(of: state.groups) { _, _ in
            rebuildGroupListCache()
        }
        .onChangeCompat(of: state.conversations) { _, _ in
            rebuildGroupListCache()
        }
        .onChangeCompat(of: state.currentUser.id) { _, _ in
            rebuildGroupListCache()
        }
        .onChangeCompat(of: state.currentUser.name) { _, _ in
            rebuildGroupListCache()
        }
        .sheet(isPresented: $showCreateGroupSheet) {
            CreateGroupSheet { conversationID in
                showCreateGroupSheet = false
                // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_CREATE_GROUP_ROUTE - 修改开始：创建群后使用同一稳定聊天 route
                selectedConversationRoute = ContactsConversationRoute(id: conversationID)
                // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_CREATE_GROUP_ROUTE - 修改结束
            }
            .environmentObject(state)
            .presentationDetentsCompat([.large])
            .presentationCornerRadiusCompat(30)
        }
        .toolbarTabBarHiddenCompat()
    }

    private func buildGroupSections() -> GroupListRenderSections {
        var managed: [GroupListRenderItem] = []
        var joined: [GroupListRenderItem] = []
        for group in projectedGroups {
            let item = GroupListRenderItem(group: group, conversation: conversation(for: group, in: state.conversations))
            if state.canManageGroup(group) {
                managed.append(item)
            } else {
                joined.append(item)
            }
        }
        return GroupListRenderSections(managed: managed, joined: joined)
    }

    private func rebuildGroupListCache() {
        cachedGroupSections = buildGroupSections()
        hasGroupListCache = true
    }

    private func startGroupDirectoryRefresh() {
        groupDirectoryRefreshTask?.cancel()
        groupDirectoryRefreshTask = Task { @MainActor in
            guard await state.refreshGroupDirectory(), !Task.isCancelled else { return }
            state.groups.forEach { group in
                state.loadGroupDetailIfNeeded(groupID: group.id)
            }
        }
    }

    private func conversation(for group: GroupInfo, in conversations: [Conversation]) -> Conversation? {
        conversations.first { conversation in
            conversation.kind == .group && (conversation.id == group.id || conversation.title == group.name)
        }
    }

    private func conversationID(for item: GroupListRenderItem) -> String {
        item.conversation?.id ?? item.group.id
    }
}

private struct GroupCreateEntryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand))
                .shadow(color: IMColor.brand.opacity(0.14), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text("创建群聊")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text("设置群名，选择好友后立即创建")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.muted.opacity(0.72))
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct GroupListRenderItem: Identifiable, Hashable {
    let group: GroupInfo
    let conversation: Conversation?

    var id: String { group.id }
}

private struct GroupListRenderSections: Hashable {
    static let empty = GroupListRenderSections(managed: [], joined: [])

    let managed: [GroupListRenderItem]
    let joined: [GroupListRenderItem]
}

private struct GroupListRow: View {
    let group: GroupInfo
    let conversation: Conversation?
    @EnvironmentObject private var state: AppState

    private var unreadBadgeColor: Color {
        isNotificationMuted ? IMColor.muted.opacity(0.62) : IMColor.danger
    }

    private var isNotificationMuted: Bool {
        GroupNotificationMuteProjection.isMuted(group: group, conversation: conversation)
    }

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatarView(name: group.name, seed: conversation?.accentHex ?? 0x5D6BFF, size: 46, imageURL: group.avatarURL, avatarVersion: group.avatarVersion, avatarUpdatedAt: group.avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(groupID: group.id, avatarURL: group.avatarURL, avatarVersion: group.avatarVersion, avatarUpdatedAt: group.avatarUpdatedAt))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                    if isNotificationMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(IMColor.muted)
                    }
                }
                Text(
                    [
                        state.visibleGroupMemberCount(
                            group.memberCount,
                            group.members.count,
                            conversation?.memberCount ?? 0,
                            conversation?.participants.count ?? 0
                        ).map { "\($0) 人" },
                        group.owner.isEmpty ? nil : "群主 \(group.owner)"
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
            }
            Spacer()
            if let unread = conversation?.unread,
               let unreadText = UnreadBadgeFormatter.text(unread) {
                Text(unreadText)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(unreadBadgeColor))
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct NewFriendsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List {
            Section {
                if state.friendRequests.isEmpty {
                    EmptyStateView(symbol: "person.crop.circle.badge.plus", title: "暂无新朋友申请", subtitle: "收到新的好友申请后，会在这里处理通过或忽略。")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(state.friendRequests) { request in
                        HStack(spacing: 12) {
                            AvatarView(name: request.name, seed: 0x5D6BFF, size: 42, imageURL: request.avatarURL, certification: state.certificationPresentation(forExactUID: request.userID))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(request.name)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    CertificationPillView(
                                        exactUID: request.userID,
                                        compact: true
                                    )
                                }
                                Text("\(request.source) · \(request.message)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(IMColor.muted)
                                    .lineLimit(1)
                                if !request.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    CopyableUserIDText(
                                        value: request.userID,
                                        prefix: "用户ID：",
                                        font: .system(size: 12, weight: .semibold),
                                        color: IMColor.muted
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            if request.isPendingIncoming {
                                HStack(spacing: 8) {
                                    FriendRequestActionButton(title: "忽略", style: .secondary) {
                                        state.rejectFriendRequest(request.id)
                                    }
                                    .accessibilityIdentifier("friend_request_reject_\(request.id)")

                                    FriendRequestActionButton(title: "接受", style: .primary) {
                                        state.acceptFriendRequest(request.id)
                                    }
                                    .accessibilityIdentifier("friend_request_accept_\(request.id)")
                                }
                                .frame(width: 114, alignment: .trailing)
                            } else if request.canCancel {
                                FriendRequestActionButton(
                                    title: state.isCancellingFriendRequest(request.id) ? "取消中" : "取消申请",
                                    style: .secondary
                                ) {
                                    Task { _ = await state.cancelFriendRequest(request.id) }
                                }
                                .disabled(state.isCancellingFriendRequest(request.id))
                                .accessibilityIdentifier("friend_request_cancel_\(request.id)")
                            } else {
                                StatusPill(
                                    title: request.statusLabel,
                                    color: request.accepted ? IMColor.success : (request.direction == "outgoing" ? IMColor.warning : IMColor.muted)
                                )
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("friend_request_row_\(request.id)")
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }
}

private struct FriendRequestActionButton: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let style: Style
    let action: () -> Void

    private var foreground: Color {
        style == .primary ? .white : IMColor.muted
    }

    private var background: Color {
        style == .primary ? IMColor.brand : Color.white.opacity(0.72)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: 52, height: 38)
                .foregroundStyle(foreground)
                .background(Capsule().fill(background))
                .overlay(
                    Capsule()
                        .stroke(style == .primary ? Color.clear : IMColor.line.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct BlacklistView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List {
            Section {
                if state.blacklist.isEmpty {
                    EmptyStateView(symbol: "hand.raised.slash.fill", title: "暂无黑名单账号", subtitle: "被移出的账号会恢复资料查看和会话入口。")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(state.blacklist) { item in
                        HStack {
                            AvatarView(name: item.name, seed: 0xFF5D73, size: 42, certification: state.certificationPresentation(forExactUID: item.id))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.system(size: 16, weight: .bold))
                                        .lineLimit(1)
                                    CertificationPillView(
                                        exactUID: item.id,
                                        compact: true
                                    )
                                }
                                CopyableUserIDText(
                                    value: item.id,
                                    prefix: "用户ID：",
                                    font: .system(size: 11, weight: .semibold),
                                    color: IMColor.muted
                                )
                                Text(item.reason)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                            Button("移出") {
                                state.removeFromBlacklist(item.id)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("blacklist_remove_\(item.id)")
                        }
                        .accessibilityIdentifier("blacklist_row_\(item.id)")
                    }
                }
            } header: {
                Text("黑名单内账号无法发起会话或查看资料")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
    }
}

struct UserProfileView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let user: IMUser
    var onOpenConversation: ((String) -> Void)? = nil
    @State private var showRemarkEditor = false
    @State private var showCardShareSheet = false
    @State private var showBlockConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isApplyingFriend = false
    @State private var friendRequestSent = false
    @State private var showAvatarPreview = false

    private enum ProfileActionMode {
        case selfProfile
        case cancelled
        case blocked
        case friend
        case pendingFriendRequest
        case nonFriend
    }

    private var liveUser: IMUser {
        state.liveProfileUser(for: user)
    }

    private var displayName: String {
        state.userProfileDisplayName(for: liveUser)
    }

    private var visiblePhone: String? {
        let phone = liveUser.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return nil }
        return phone
    }

    private var isSelfProfile: Bool {
        state.isCurrentUserProfile(liveUser)
    }

    private var isCancelledProfile: Bool {
        state.isCancelledProfile(liveUser)
    }

    private var previewAvatarSource: String? {
        OtherUserAvatarPreviewPolicy.source(
            for: liveUser,
            isSelf: isSelfProfile,
            isCancelled: isCancelledProfile
        )
    }

    private var isFriendProfile: Bool {
        state.canStartDirectConversation(with: liveUser)
    }

    private var isBlockedProfile: Bool {
        state.isBlockedProfile(liveUser)
    }

    private var profileUserID: String {
        let value = liveUser.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? liveUser.id : value
    }

    private var hasPendingFriendRequest: Bool {
        friendRequestSent || state.hasPendingOutgoingFriendRequest(with: liveUser)
    }

    private var profileActionMode: ProfileActionMode {
        if isSelfProfile { return .selfProfile }
        if isCancelledProfile { return .cancelled }
        if isBlockedProfile { return .blocked }
        if isFriendProfile { return .friend }
        if hasPendingFriendRequest { return .pendingFriendRequest }
        return .nonFriend
    }

    private var addFriendButtonTitle: String {
        if hasPendingFriendRequest { return FriendAddPresentation.waitingTitle }
        if isApplyingFriend { return "发送中" }
        return FriendAddPresentation.actionTitle
    }

    private var addFriendButtonDisabled: Bool {
        hasPendingFriendRequest || isApplyingFriend
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    profileSummaryCard

                    switch profileActionMode {
                    case .friend:
                        HStack(spacing: 10) {
                            PrimaryButton(title: "发起会话", systemImage: "bubble.left.fill") {
                                guard let conversationID = state.openOrCreateDirectConversationID(for: liveUser, activateChatsTab: false) else { return }
                                if let onOpenConversation {
                                    onOpenConversation(conversationID)
                                } else {
                                    state.toast = "已进入与 \(displayName) 的会话"
                                    dismiss()
                                }
                            }
                            .accessibilityIdentifier("profile_start_chat_button")
                            IconButton(symbol: "phone.fill") {
                                state.startOutgoingVoiceCall(to: liveUser)
                            }
                            .accessibilityIdentifier("profile_call_button")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("资料操作")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .padding(.horizontal, 2)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ProfileInlineActionButton(title: "设置备注", symbol: "pencil", tint: IMColor.brand) {
                                    showRemarkEditor = true
                                }
                                .accessibilityIdentifier("profile_set_remark_button")
                                ProfileInlineActionButton(title: "发送名片", symbol: "person.text.rectangle", tint: IMColor.cyan) {
                                    showCardShareSheet = true
                                }
                                .accessibilityIdentifier("profile_share_card_button")
                                ProfileInlineActionButton(title: "拉黑", symbol: "hand.raised.fill", tint: IMColor.danger, isDestructive: true) {
                                    showBlockConfirm = true
                                }
                                .accessibilityIdentifier("profile_block_button")
                                ProfileInlineActionButton(title: "删除好友", symbol: "trash.fill", tint: IMColor.danger, isDestructive: true) {
                                    showDeleteConfirm = true
                                }
                                .accessibilityIdentifier("profile_delete_friend_button")
                            }
                        }
                        .plainCard(radius: 24)
                    case .nonFriend, .pendingFriendRequest:
                        if state.canCurrentUserInitiateFriendRequest || hasPendingFriendRequest {
                            PrimaryButton(title: addFriendButtonTitle, systemImage: "person.badge.plus", disabled: addFriendButtonDisabled) {
                                guard !addFriendButtonDisabled else { return }
                                Task {
                                    isApplyingFriend = true
                                    let sent = await state.applyFriend(to: liveUser, source: "profile")
                                    isApplyingFriend = false
                                    if sent {
                                        friendRequestSent = true
                                    }
                                }
                            }
                            .accessibilityIdentifier("profile_add_friend_button")
                        } else {
                            Label("管理员已关闭好友申请", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                        }
                    case .cancelled:
                        Label("该用户已注销，无法互动", systemImage: "person.crop.circle.badge.xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                    case .selfProfile, .blocked:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 48)
                .padding(.bottom, 18)
            }

        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTabBarHiddenCompat()
        .fullScreenCover(isPresented: $showAvatarPreview) {
            if let previewAvatarSource {
                UserAvatarPreviewSheet(
                    user: liveUser,
                    displayName: displayName,
                    source: previewAvatarSource
                )
            }
        }
        .sheet(isPresented: $showRemarkEditor) {
            ContactRemarkEditSheet(user: liveUser)
                .presentationDetentsCompat([.height(310)])
        }
        .sheet(isPresented: $showCardShareSheet) {
            ContactCardShareSheet(user: liveUser)
                .presentationDetentsCompat([.medium, .large])
        }
        .alert("拉黑 \(displayName)？", isPresented: $showBlockConfirm) {
            Button("取消", role: .cancel) {}
            Button("拉黑", role: .destructive) {
                state.blockContact(liveUser)
            }
        } message: {
            Text("拉黑后该用户会从通讯录和单聊入口移除，并进入黑名单。")
        }
        .alert("删除好友 \(displayName)？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除好友", role: .destructive) {
                state.deleteContact(liveUser)
                dismiss()
            }
        } message: {
            Text("删除后会从通讯录和单聊入口移除该好友。")
        }
    }

    private var profileCloseButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.88)))
                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭资料页")
    }

    private var profileSummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                profileAvatar
                VStack(alignment: .leading, spacing: 7) {
                    profileIdentity
                    if isCancelledProfile {
                        StatusPill(title: "已注销", color: IMColor.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 44)

            Rectangle()
                .fill(IMColor.line.opacity(0.72))
                .frame(height: 1)

            if isBlockedProfile {
                VStack(alignment: .leading, spacing: 10) {
                    Label("该用户已在黑名单中", systemImage: "hand.raised.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.danger)
                    ProfileInfoRow(title: "用户ID", value: profileUserID, copyValue: profileUserID)
                    Text("已拉黑用户不展示完整资料，也不能发起会话、发送名片或文件。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 12) {
                    ProfileInfoRow(title: "企业", value: liveUser.enterprise)
                    if let department = state.departmentSummary(for: liveUser, fullPath: true) {
                        ProfileInfoRow(title: "部门", value: department)
                    }
                    ProfileInfoRow(title: "用户ID", value: profileUserID, copyValue: profileUserID)
                    if let visiblePhone {
                        ProfileInfoRow(title: "手机号", value: visiblePhone)
                    }
                    ProfileInfoRow(title: "备注", value: state.contactRemark(for: liveUser))
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.white.opacity(0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.76), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            profileCloseButton
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
        .shadow(color: IMColor.brand.opacity(0.08), radius: 18, y: 8)
    }

    @ViewBuilder
    private var profileIdentity: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    profileName
                    profileCertification
                }
                .fixedSize(horizontal: true, vertical: true)
                stackedProfileIdentity
            }
        } else {
            // iOS 15 has no ViewThatFits; use the fully readable fallback.
            stackedProfileIdentity
        }
    }

    private var stackedProfileIdentity: some View {
        VStack(alignment: .leading, spacing: 7) {
            profileName
            profileCertification
        }
    }

    private var profileName: some View {
        Text(displayName)
            .font(.system(size: 24, weight: .black))
            .foregroundStyle(IMColor.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var profileCertification: some View {
        CertificationPillView(exactUID: liveUser.id, maximumLineCount: nil)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if previewAvatarSource != nil {
            Button {
                guard !showAvatarPreview else { return }
                showAvatarPreview = true
            } label: {
                profileAvatarImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(displayName)的头像大图")
            .accessibilityHint("打开全屏头像预览")
            .accessibilityIdentifier("other_user_avatar_preview_button")
        } else {
            profileAvatarImage
        }
    }

    private var profileAvatarImage: some View {
        AvatarView(
            name: displayName,
            seed: liveUser.avatarSeed,
            size: 72,
            imageURL: liveUser.displayAvatarURL,
            avatarVersion: liveUser.avatarVersion,
            avatarUpdatedAt: liveUser.avatarUpdatedAt,
            certification: state.certificationPresentation(forExactUID: liveUser.id)
        )
    }
}

private enum UserAvatarPreviewLoadPhase {
    case loading
    case loaded(UIImage)
    case failed
}

struct UserAvatarPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.avatarImageRouteContext) private var avatarImageRouteContext
    let user: IMUser
    let displayName: String
    let source: String
    @State private var loadPhase: UserAvatarPreviewLoadPhase = .loading
    @State private var retryGeneration = 0
    @State private var dismissalOffset: CGSize = .zero
    @State private var dismissalCoordinator = AttachmentImagePreviewDismissalCoordinator()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button {
                    requestDismissal(.closeButton)
                } label: {
                    Color.black.opacity(0.96).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("点击遮罩关闭头像预览")

                previewContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 64)
            }
            .overlay(alignment: .topTrailing) {
                IconButton(symbol: "xmark", tint: .white) {
                    requestDismissal(.closeButton)
                }
                .accessibilityLabel("关闭头像预览")
                .accessibilityIdentifier("other_user_avatar_preview_close_button")
                .safeAreaPaddingTopCompat(8)
                .padding(.trailing, 16)
            }
            .contentShape(Rectangle())
            .offset(dismissalOffset)
            .opacity(
                AttachmentImagePreviewDismissalPolicy.dismissalOpacity(
                    offset: dismissalOffset,
                    viewportSize: proxy.size
                )
            )
            .simultaneousGesture(dismissalGesture(in: proxy.size))
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: loadIdentity) {
            await loadAvatar()
        }
        .accessibilityAction(.escape) {
            requestDismissal(.accessibilityEscape)
        }
        .accessibilityAction(named: Text("关闭头像预览")) {
            requestDismissal(.accessibilityEscape)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch loadPhase {
        case .loading:
            ProgressView()
                .tint(.white)
                .accessibilityLabel("正在加载头像大图")
        case .loaded(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("\(displayName)的头像大图")
                .allowsHitTesting(false)
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36, weight: .bold))
                Text("头像加载失败")
                    .font(.system(size: 15, weight: .bold))
                Button("重试") {
                    retryGeneration += 1
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("other_user_avatar_preview_retry_button")
            }
            .foregroundStyle(.white.opacity(0.92))
        }
    }

    private var loadIdentity: String {
        "\(user.id)|\(source)|\(user.avatarVersion)|\(user.avatarUpdatedAt)|retry=\(retryGeneration)"
    }

    @MainActor
    private func loadAvatar() async {
        loadPhase = .loading
        let image = await AvatarImageCache.shared.remoteImage(
            for: source,
            routeContext: avatarImageRouteContext,
            cacheKey: user.avatarCacheKey,
            maxPixelSize: nil,
            retryPolicy: .none
        )
        guard !Task.isCancelled else { return }
        loadPhase = image.map(UserAvatarPreviewLoadPhase.loaded) ?? .failed
    }

    private func dismissalGesture(in viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                dismissalOffset = AttachmentImagePreviewDismissalPolicy.interactiveOffset(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    viewportSize: viewportSize,
                    scale: 1
                )
            }
            .onEnded { value in
                let trigger = AttachmentImagePreviewDismissalPolicy.dismissalTrigger(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    viewportSize: viewportSize,
                    scale: 1
                )
                if let trigger {
                    requestDismissal(trigger)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dismissalOffset = .zero
                    }
                }
            }
    }

    private func requestDismissal(_ trigger: AttachmentImagePreviewDismissalTrigger) {
        guard dismissalCoordinator.request(trigger) else { return }
        dismiss()
    }
}

private struct ProfileInlineActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(isDestructive ? IMColor.danger : IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isDestructive ? IMColor.danger.opacity(0.06) : IMColor.page.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(isDestructive ? 0.16 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ContactRemarkEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let user: IMUser
    @State private var draftRemark = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    private var remarkCount: Int {
        FriendRemarkInputPolicy.unicodeCodePointCount(draftRemark)
    }

    private var validationMessage: String? {
        FriendRemarkInputPolicy.validationMessage(for: draftRemark)
    }

    private func save(_ remark: String) {
        guard !isSaving else { return }
        if let validationMessage = FriendRemarkInputPolicy.validationMessage(for: remark) {
            saveErrorMessage = validationMessage
            return
        }
        isSaving = true
        saveErrorMessage = nil
        state.setContactRemark(remark, for: user) { result in
            isSaving = false
            switch result {
            case .success:
                dismiss()
            case .failure(let failure):
                saveErrorMessage = failure.message
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(symbol: "pencil", title: "设置备注", subtitle: "备注仅自己可见，用于通讯录和资料页识别。", showsCloseButton: true)
            FormInput(title: "好友备注", placeholder: "输入备注名称", text: $draftRemark)
                .disabled(isSaving)
            HStack {
                Spacer()
                Text("\(remarkCount)/\(FriendRemarkInputPolicy.maxUnicodeCodePoints)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(validationMessage == nil ? IMColor.muted : IMColor.danger)
                    .accessibilityLabel("已输入 \(remarkCount) 个字符，最多 \(FriendRemarkInputPolicy.maxUnicodeCodePoints) 个")
            }
            if let message = saveErrorMessage ?? validationMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .accessibilityIdentifier("contact_remark_save_error")
            }
            HStack(spacing: 10) {
                Button {
                    draftRemark = ""
                    save("")
                } label: {
                    Text("清空")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.page))
                }
                .disabled(isSaving)
                .accessibilityIdentifier("contact_remark_clear_button")
                PrimaryButton(
                    title: isSaving ? "保存中" : "保存",
                    systemImage: isSaving ? "clock" : "checkmark",
                    disabled: isSaving || validationMessage != nil
                ) {
                    save(draftRemark)
                }
                .accessibilityIdentifier("contact_remark_save_button")
            }
        }
        .padding(20)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            let currentRemark = state.contactRemark(for: user)
            draftRemark = currentRemark == "未设置" ? "" : currentRemark
        }
        .onChangeCompat(of: draftRemark) { _, _ in
            saveErrorMessage = nil
        }
    }
}

private struct ContactCardShareSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let user: IMUser

    private var shareTargets: [Conversation] {
        state.conversations.filter { $0.kind != .system }
    }

    private var displayName: String {
        state.remarkPreferredDisplayName(for: user)
    }

    private func displayName(for conversation: Conversation) -> String {
        guard conversation.kind == .direct,
              let peer = state.directConversationCallPeer(for: conversation) else {
            return conversation.title
        }
        return state.remarkPreferredDisplayName(for: peer)
    }

    private func shareTargetTag(for kind: ConversationKind) -> (title: String, color: Color)? {
        switch kind {
        case .group:
            return ("群聊", IMColor.brand)
        case .system:
            return ("系统", IMColor.cyan)
        case .direct:
            return nil
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(symbol: "person.text.rectangle", title: "发送名片", subtitle: "选择一个会话，将该好友名片发送到聊天中。", showsCloseButton: true)
                        HStack(spacing: 12) {
                            AvatarView(name: displayName, seed: user.avatarSeed, size: 54, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(displayName)
                                        .font(.system(size: 18, weight: .black))
                                        .foregroundStyle(IMColor.ink)
                                        .lineLimit(1)
                                    CertificationPillView(
                                        exactUID: user.id,
                                        compact: true
                                    )
                                }
                                Text("企业名片")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                            StatusPill(title: "名片", color: IMColor.brand)
                        }
                        .plainCard(radius: 22)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("发送到")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            ForEach(shareTargets) { conversation in
                                let targetDisplayName = displayName(for: conversation)
                                Button {
                                    state.shareContactCard(user, to: conversation.id)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        if conversation.kind == .group {
                                            GroupAvatarView(name: targetDisplayName, seed: conversation.accentHex, size: 42, imageURL: conversation.avatarURL, avatarVersion: conversation.avatarVersion, avatarUpdatedAt: conversation.avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(for: conversation))
                                        } else {
                                            AvatarView(name: targetDisplayName, seed: conversation.accentHex, size: 42, certification: state.certificationPresentation(forExactUID: conversation.participants.first?.id ?? ""))
                                        }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(targetDisplayName)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(IMColor.ink)
                                                .lineLimit(1)
                                            if conversation.kind == .direct {
                                                CertificationPillView(
                                                    exactUID: conversation.participants.first?.id ?? "",
                                                    compact: true
                                                )
                                            }
                                            if let conversationTag = shareTargetTag(for: conversation.kind) {
                                                StatusPill(title: conversationTag.title, color: conversationTag.color)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "paperplane.fill")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(IMColor.brand)
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.88)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ProfileInfoRow: View {
    @EnvironmentObject private var state: AppState
    let title: String
    let value: String
    var copyValue: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IMColor.muted)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(IMColor.ink)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            guard let copyValue else { return }
            state.copyUserID(copyValue)
        })
        .accessibilityLabel(copyValue == nil ? "\(title) \(value)" : "\(title) \(value)，点击复制")
    }
}

struct GroupDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    var onSearchHistory: (() -> Void)? = nil
    var onPinnedMessages: (() -> Void)? = nil
    @State private var activeSheet: GroupDetailSheet?
    @State private var forcedAuthPromptDeferralToken: UUID?
    @State private var showLeaveDetail = false
    @State private var showDissolveDetail = false
    @State private var dissolvePreview: RemoteGroupDissolvePreview?
    @State private var dissolvePreviewScopeKey: String?
    @State private var dissolvePreviewError: String?
    @State private var isDissolvePreviewLoading = false
    @State private var isLifecycleActionRunning = false
    @State private var lifecycleInlineMessage: String?
    @State private var lifecycleActionScopeKey = ""
    @State private var lifecycleActionActorID = ""
    @State private var lifecycleActionGroupID = ""

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canManage: Bool {
        state.canManageGroup(currentGroup)
    }

    private var currentConversation: Conversation? {
        state.conversations.first { conversation in
            conversation.kind == .group
                && (conversation.id == currentGroup.id || conversation.title == currentGroup.name)
        }
    }

    private var isNotificationMuted: Bool {
        GroupNotificationMuteProjection.isMuted(
            group: currentGroup,
            conversation: currentConversation
        )
    }

    private var isCurrentUserOwner: Bool {
        currentGroup.isCurrentUserOwner || state.isGroupOwner(state.currentUser, in: currentGroup)
    }

    private func lifecycleActionContextIsCurrent(groupID: String, requiresOwner: Bool) -> Bool {
        guard !lifecycleActionScopeKey.isEmpty,
              lifecycleActionGroupID == groupID,
              state.contentCacheScopeKey == lifecycleActionScopeKey,
              state.currentUser.id == lifecycleActionActorID,
              let refreshedGroup = state.group(id: groupID) else {
            return false
        }
        let isOwner = refreshedGroup.isCurrentUserOwner
            || state.isGroupOwner(state.currentUser, in: refreshedGroup)
        return requiresOwner ? isOwner : !isOwner
    }

    private func captureLifecycleActionContext(groupID: String) {
        lifecycleActionScopeKey = state.contentCacheScopeKey
        lifecycleActionActorID = state.currentUser.id
        lifecycleActionGroupID = groupID
    }

    private func clearLifecycleActionContext() {
        lifecycleActionScopeKey = ""
        lifecycleActionActorID = ""
        lifecycleActionGroupID = ""
        dissolvePreviewScopeKey = nil
    }

    private var isConversationPinned: Bool {
        state.conversation(id: currentGroup.id).isPinned
    }

    private var pinnedMessageCount: Int {
        state.conversation(id: currentGroup.id).messages.filter { message in
            message.isPinned && message.status != .recalled
        }.count
    }

    private var roleTitle: String {
        if currentGroup.isCurrentUserOwner || state.isGroupOwner(state.currentUser, in: currentGroup) {
            return "群主"
        }
        if state.canManageGroup(currentGroup) {
            return "管理员"
        }
        return "成员"
    }

    private var roleColor: Color {
        roleTitle == "成员" ? IMColor.muted : IMColor.success
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
	                        VStack(alignment: .leading, spacing: 14) {
	                            HStack {
	                                GroupAvatarView(name: currentGroup.name, seed: 0x5D6BFF, size: 64, imageURL: currentGroup.avatarURL, avatarVersion: currentGroup.avatarVersion, avatarUpdatedAt: currentGroup.avatarUpdatedAt, imageCacheKey: state.groupAvatarCacheKey(groupID: currentGroup.id, avatarURL: currentGroup.avatarURL, avatarVersion: currentGroup.avatarVersion, avatarUpdatedAt: currentGroup.avatarUpdatedAt))
	                                VStack(alignment: .leading, spacing: 6) {
	                                    Text(currentGroup.name)
	                                        .font(.system(size: 22, weight: .black))
	                                        .foregroundStyle(IMColor.ink)
		                                    Text(
                                                [
                                                    state.visibleGroupMemberCount(
                                                        currentGroup.memberCount,
                                                        currentGroup.members.count
                                                    ).map { "\($0) 人" },
                                                    currentGroup.owner.isEmpty ? nil : "群主 \(currentGroup.owner)"
                                                ]
                                                .compactMap { $0 }
                                                .joined(separator: " · ")
                                            )
	                                        .font(.system(size: 13, weight: .semibold))
	                                        .foregroundStyle(IMColor.muted)
		                                }
		                                Spacer()
                                        HStack(spacing: 8) {
                                            StatusPill(title: roleTitle, color: roleColor)
                                            if canManage {
                                                Button {
                                                    activeSheet = .profile
                                                } label: {
                                                    Image(systemName: "square.and.pencil")
                                                        .font(.system(size: 15, weight: .black))
                                                        .foregroundStyle(IMColor.brand)
                                                        .frame(width: 36, height: 36)
                                                        .background(Circle().fill(IMColor.brand.opacity(0.10)))
                                                        .overlay(Circle().stroke(IMColor.brand.opacity(0.14), lineWidth: 1))
                                                }
                                                .buttonStyle(.plain)
                                                .contentShape(Circle())
                                                .accessibilityLabel("编辑群资料")
                                            }
                                        }
		                            }
	                            Text(currentGroup.notice)
	                                .font(.system(size: 13, weight: .semibold))
	                                .foregroundStyle(IMColor.muted)
	                                .padding(12)
	                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.08)))
                                if !currentGroup.groupDescription.isEmpty {
                                    Label(currentGroup.groupDescription, systemImage: "text.alignleft")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(IMColor.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.violet.opacity(0.07)))
                                }
                        }
                        .glassCard(radius: 28)

			                        VStack(spacing: 12) {
				                            SettingsRow(symbol: "person.3.fill", title: "群成员", subtitle: canManage ? "邀请、移除、设置管理员" : "查看群成员") {
				                                activeSheet = .members
				                            }
                                        SettingsRow(
                                            symbol: "person.text.rectangle.fill",
                                            title: "我的群昵称",
                                            subtitle: state.myGroupNickname(groupID: currentGroup.id).isEmpty
                                                ? "未设置，显示全局昵称"
                                                : state.myGroupNickname(groupID: currentGroup.id)
                                        ) {
                                            activeSheet = .myNickname
                                        }
			                            SettingsRow(symbol: "megaphone.fill", title: "群公告", subtitle: canManage ? "公告查看、发布" : "公告查看") {
			                                activeSheet = .announcement
			                            }
			                            SettingsRow(symbol: "folder.fill", title: "群文件", subtitle: "文件预览、下载、转发") {
			                                activeSheet = .files
			                            }
                                        SettingsRow(
                                            symbol: "pin.square.fill",
                                            title: "群内置顶消息",
                                            subtitle: pinnedMessageCount > 0 ? "\(pinnedMessageCount) 条置顶消息" : "查看、定位、取消置顶"
                                        ) {
                                            onPinnedMessages?()
                                        }
	                                        SettingsRow(
	                                            symbol: isConversationPinned ? "pin.slash.fill" : "pin.fill",
	                                            title: isConversationPinned ? "取消置顶" : "置顶会话",
                                            subtitle: isConversationPinned ? "已固定在会话列表顶部" : "固定在会话列表顶部"
                                        ) {
                                            state.togglePinned(currentGroup.id)
                                        }
                                        if canManage {
					                                SettingsRow(symbol: "speaker.slash.fill", title: "全员禁言", subtitle: currentGroup.allMuteStatusText()) {
					                                    activeSheet = .muteAll
					                                }
                                        }
                                        SettingsRow(
                                            symbol: "person.crop.circle.badge.exclamationmark.fill",
                                            title: "禁言名单",
                                            subtitle: currentGroup.muteListStatusText,
                                            tint: IMColor.warning
                                        ) {
                                            activeSheet = .muteList
                                        }
			                            SettingsRow(symbol: "bell.slash.fill", title: "群免打扰", subtitle: isNotificationMuted ? "已开启" : "通知开启") {
			                                activeSheet = .mute
			                            }
                                        if canManage {
                                            SettingsRow(
                                                symbol: "person.badge.shield.checkmark.fill",
                                                title: "入群审批",
                                                subtitle: currentGroup.inviteConfirmRequired ? "已开启" : "未开启"
                                            ) {
                                                if forcedAuthPromptDeferralToken == nil {
                                                    forcedAuthPromptDeferralToken = state.beginForcedAppPolicyAuthPromptDeferral()
                                                }
                                                activeSheet = .joinApproval
                                            }
                                        }
                                        SettingsRow(
                                            symbol: "clock.arrow.circlepath",
                                            title: "新成员可查看入群前消息",
                                            subtitle: currentGroup.historyVisibilityStatusText
                                        ) {
                                            activeSheet = .historyVisibility
                                        }
                                        if isCurrentUserOwner {
                                            GroupLifecycleActionRow(
                                                symbol: "xmark.octagon",
                                                title: "解散群聊"
                                            ) {
                                                guard !isLifecycleActionRunning else { return }
                                                captureLifecycleActionContext(groupID: currentGroup.id)
                                                lifecycleInlineMessage = nil
                                                dissolvePreview = nil
                                                dissolvePreviewScopeKey = nil
                                                dissolvePreviewError = nil
                                                showDissolveDetail = true
                                            }
                                            .accessibilityIdentifier("group_detail_dissolve_button")
                                        } else {
                                            GroupLifecycleActionRow(
                                                symbol: "rectangle.portrait.and.arrow.right",
                                                title: "退出群聊"
                                            ) {
                                                guard !isLifecycleActionRunning else { return }
                                                captureLifecycleActionContext(groupID: currentGroup.id)
                                                lifecycleInlineMessage = nil
                                                showLeaveDetail = true
                                            }
                                            .accessibilityIdentifier("group_detail_leave_button")
                                        }
					                        }
	                        .plainCard(radius: 24)
                    }
                    .padding(18)
                    .padding(.top, 42)
                }
                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(.white.opacity(0.94)))
                                .overlay(Circle().stroke(IMColor.line, lineWidth: 1))
                                .shadow(color: IMColor.brand.opacity(0.10), radius: 14, y: 6)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .accessibilityLabel("关闭群详情")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    Spacer()
                }
	                .zIndex(5)
	            }
	                .navigationTitle("")
	                .navigationBarTitleDisplayMode(.inline)
	                .navigationDestinationCompat(item: $activeSheet) { sheet in
	                    switch sheet {
	                    case .members:
	                        GroupMemberManagementView(groupID: currentGroup.id)
	                    case .announcement:
	                        GroupAnnouncementSheet(group: currentGroup)
	                    case .files:
	                        GroupFilesSheet(group: currentGroup)
	                    case .profile:
	                        GroupProfileEditSheet(group: currentGroup)
	                    case .myNickname:
	                        GroupNicknameEditSheet(groupID: currentGroup.id)
		                    case .muteAll:
		                        GroupMuteAllSheet(group: currentGroup)
		                    case .mute:
	                        GroupMuteSheet(group: currentGroup)
	                    case .muteList:
	                        GroupMuteListSheet(group: currentGroup)
		                    case .joinApproval:
		                        GroupJoinApprovalSheet(group: currentGroup)
		                            .onDisappear {
		                                endForcedAuthPromptDeferralIfNeeded()
		                            }
	                    case .historyVisibility:
	                        GroupHistoryVisibilitySheet(group: currentGroup)
		                    }
		                }
	                .onChangeCompat(of: activeSheet) { _, sheet in
	                    if sheet == nil {
	                        endForcedAuthPromptDeferralIfNeeded()
	                    }
	                }
	                .navigationDestinationCompat(isPresented: $showLeaveDetail) {
	                    GroupLeaveDetailSheet(
	                        group: currentGroup,
	                        isSubmitting: isLifecycleActionRunning,
	                        isScopeValid: lifecycleActionContextIsCurrent(
                            groupID: currentGroup.id,
                            requiresOwner: false
                        ),
                        actionErrorMessage: lifecycleInlineMessage
                    ) {
                        showLeaveDetail = false
                        lifecycleInlineMessage = nil
                        clearLifecycleActionContext()
	                    } onConfirm: {
	                        performLeaveGroup()
	                    }
	                    .interactiveDismissDisabled(isLifecycleActionRunning)
	                }
	                .navigationDestinationCompat(isPresented: $showDissolveDetail) {
	                    GroupDissolveConfirmSheet(
	                        group: currentGroup,
	                        preview: dissolvePreview,
	                        isSubmitting: isLifecycleActionRunning && !isDissolvePreviewLoading,
                        isPreviewLoading: isDissolvePreviewLoading,
                        isScopeValid: lifecycleActionContextIsCurrent(
                            groupID: currentGroup.id,
                            requiresOwner: true
                        ),
                        isPreviewScopeValid: !lifecycleActionScopeKey.isEmpty
                            && dissolvePreviewScopeKey == lifecycleActionScopeKey,
                        previewErrorMessage: dissolvePreviewError,
                        actionErrorMessage: lifecycleInlineMessage,
                        onRetryPreview: {
                            beginDissolvePreview()
                        }
                    ) {
                        showDissolveDetail = false
                        dissolvePreview = nil
                        dissolvePreviewError = nil
                        lifecycleInlineMessage = nil
                        clearLifecycleActionContext()
	                    } onConfirm: {
	                        performDissolveGroup()
	                    }
	                    .interactiveDismissDisabled(isLifecycleActionRunning)
	                    .onAppear {
	                        guard dissolvePreview == nil,
                              dissolvePreviewError == nil,
                              !isDissolvePreviewLoading else { return }
                        beginDissolvePreview()
                    }
	                }
	                .onAppear {
	                    state.loadGroupDetailIfNeeded(groupID: group.id)
	                }
						    }
					}

    private func beginDissolvePreview() {
        guard !isLifecycleActionRunning else { return }
        let groupID = currentGroup.id
        guard lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: true) else {
            dissolvePreview = nil
            dissolvePreviewScopeKey = nil
            dissolvePreviewError = "群聊状态、账号或你的群角色已变化，请返回后重试"
            return
        }
        let expectedScopeKey = lifecycleActionScopeKey
        let expectedActorID = lifecycleActionActorID
        isLifecycleActionRunning = true
        isDissolvePreviewLoading = true
        dissolvePreview = nil
        dissolvePreviewScopeKey = nil
        dissolvePreviewError = nil
        lifecycleInlineMessage = nil
        Task {
            let preview = await state.previewDissolveGroup(groupID: groupID)
            isLifecycleActionRunning = false
            isDissolvePreviewLoading = false
            guard showDissolveDetail else { return }
            guard lifecycleActionScopeKey == expectedScopeKey,
                  lifecycleActionActorID == expectedActorID,
                  lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: true) else {
                dissolvePreview = nil
                dissolvePreviewScopeKey = nil
                dissolvePreviewError = "群聊状态、账号或你的群角色已变化，请返回后重试"
                return
            }
            if let preview, preview.groupID == groupID {
                dissolvePreview = preview
                dissolvePreviewScopeKey = expectedScopeKey
            } else {
                dissolvePreviewScopeKey = nil
                dissolvePreviewError = state.toast ?? "解散预览失败，请稍后重试"
            }
        }
    }

    private func performLeaveGroup() {
        guard !isLifecycleActionRunning else { return }
        let groupID = currentGroup.id
        guard lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: false) else {
            lifecycleInlineMessage = "群聊状态、账号或你的群角色已变化，请返回后重试"
            return
        }
        isLifecycleActionRunning = true
        lifecycleInlineMessage = nil
        Task {
            let ok = await state.leaveGroup(groupID: groupID)
            isLifecycleActionRunning = false
            if ok {
                dismiss()
            } else {
                lifecycleInlineMessage = state.toast ?? "退出群聊失败，请稍后重试"
            }
	        }
	    }

	    private func endForcedAuthPromptDeferralIfNeeded() {
	        guard let token = forcedAuthPromptDeferralToken else { return }
	        forcedAuthPromptDeferralToken = nil
	        state.endForcedAppPolicyAuthPromptDeferral(token)
	    }

	    private func performDissolveGroup() {
	        guard !isLifecycleActionRunning else { return }
	        let groupID = currentGroup.id
        guard lifecycleActionContextIsCurrent(groupID: groupID, requiresOwner: true),
              dissolvePreview?.groupID == groupID,
              dissolvePreviewScopeKey == lifecycleActionScopeKey else {
            lifecycleInlineMessage = "群聊状态、账号或你的群角色已变化，请重新读取影响范围"
            return
        }
        isLifecycleActionRunning = true
        lifecycleInlineMessage = nil
        Task {
            let ok = await state.dissolveGroup(groupID: groupID)
            isLifecycleActionRunning = false
            if ok {
                showDissolveDetail = false
                dismiss()
            } else {
                lifecycleInlineMessage = state.toast ?? "解散该群失败，请稍后重试"
            }
        }
    }

	private enum GroupDetailSheet: String, Identifiable, Hashable {
    case members
    case announcement
    case files
    case profile
    case myNickname
    case muteAll
    case mute
    case muteList
    case joinApproval
    case historyVisibility

    var id: String { rawValue }
}

}

private struct GroupNicknameEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let groupID: String

    @State private var nickname = ""
    @State private var originalNickname = ""
    @State private var isSaving = false
    @State private var inlineMessage: String?
    @State private var didLoad = false

    private var normalizedNickname: String? {
        try? GroupNicknameInputPolicy.normalize(nickname)
    }

    private var validationMessage: String? {
        do {
            _ = try GroupNicknameInputPolicy.normalize(nickname)
            return nil
        } catch let error as GroupNicknameInputError {
            return error.userMessage
        } catch {
            return "群昵称格式不正确"
        }
    }

    private var canSave: Bool {
        guard !isSaving, validationMessage == nil, let normalizedNickname else { return false }
        return normalizedNickname != originalNickname
    }

    var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            VStack(alignment: .leading, spacing: 16) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("我的群昵称")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("仅在当前群生效；留空保存可清除。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.78)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭群昵称编辑")
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("输入群昵称", text: $nickname)
                        .font(.system(size: 17, weight: .bold))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .imReadableInputText()
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(.white.opacity(0.94))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .stroke(validationMessage == nil ? IMColor.line : IMColor.danger, lineWidth: 1)
                                )
                        )
                        .disabled(isSaving)
                        .accessibilityLabel("当前群的群昵称")
                        .accessibilityHint("最多 64 个 Unicode 字符，留空可清除")
                        .accessibilityIdentifier("group_nickname_input")

                    HStack {
                        Text(validationMessage ?? inlineMessage ?? "优先显示群昵称，未设置时显示好友备注或个人昵称。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                validationMessage != nil
                                    ? IMColor.danger
                                    : (inlineMessage?.contains("成功") == true ? IMColor.success : IMColor.muted)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text("\(nickname.unicodeScalars.count)/64")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(nickname.unicodeScalars.count > 64 ? IMColor.danger : IMColor.muted)
                            .accessibilityLabel("已输入 \(nickname.unicodeScalars.count) 个字符，最多 64 个")
                    }
                }
                .plainCard(radius: 22)

                PrimaryButton(
                    title: isSaving ? "保存中..." : (normalizedNickname?.isEmpty == true ? "清除群昵称" : "保存群昵称"),
                    systemImage: normalizedNickname?.isEmpty == true ? "trash.fill" : "checkmark.circle.fill",
                    disabled: !canSave
                ) {
                    save()
                }
                .accessibilityIdentifier("group_nickname_save_button")
            }
            .padding(18)
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            let current = state.myGroupNickname(groupID: groupID)
            originalNickname = current
            nickname = current
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        inlineMessage = nil
        Task {
            let ok = await state.updateMyGroupNickname(groupID: groupID, rawValue: nickname)
            isSaving = false
            if ok {
                inlineMessage = "群昵称保存成功"
                dismiss()
            } else {
                inlineMessage = state.toast ?? "群昵称保存失败"
            }
        }
    }
}

private struct GroupLifecycleActionRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(IMColor.danger.opacity(0.10)))
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(IMColor.danger)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(IMColor.muted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct GroupLeaveDetailSheet: View {
    let group: GroupInfo
    let isSubmitting: Bool
    let isScopeValid: Bool
    let actionErrorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showFinalConfirmation = false

    private var canContinue: Bool {
        isScopeValid && !isSubmitting
    }

    var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(IMColor.muted.opacity(0.22))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(IMColor.danger))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("退出群聊")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text(group.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("退出后的影响")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        GroupDissolveEffectRow(symbol: "bell.slash.fill", text: "你将不再接收该群的新消息")
                        GroupDissolveEffectRow(symbol: "bubble.left.and.bubble.right.fill", text: "该群会话会从你的会话列表中移除")
                        GroupDissolveEffectRow(symbol: "person.crop.circle.badge.minus", text: "其他群成员不会被移出，群聊仍会继续")
                    }
                    .plainCard(radius: 22)

                    Text("退出后如需重新加入，需由群成员再次邀请或重新申请。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isScopeValid {
                        Text("群聊状态、账号或你的群角色已变化，请返回后重试")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_leave_scope_error")
                    }

                    if let actionErrorMessage, !actionErrorMessage.isEmpty {
                        Text(actionErrorMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_leave_error_message")
                    }

                    HStack(spacing: 10) {
                        Button {
                            guard !isSubmitting else { return }
                            onCancel()
                            dismiss()
                        } label: {
                            Text("取消")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(IMColor.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(.white.opacity(0.88))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .opacity(isSubmitting ? 0.62 : 1)
                        .accessibilityIdentifier("group_leave_cancel_button")

                        Button(role: .destructive) {
                            guard canContinue else { return }
                            showFinalConfirmation = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                                Text(isSubmitting ? "退出中..." : "退出群聊")
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(canContinue ? IMColor.danger : Color(hex: 0xB8C0D8))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canContinue)
                        .accessibilityIdentifier("group_leave_continue_button")
                    }
                }
                .padding(18)
            }
        }
        .alert("最终确认退出群聊？", isPresented: $showFinalConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认退出", role: .destructive) {
                guard canContinue else { return }
                onConfirm()
            }
            .accessibilityIdentifier("group_leave_final_confirm_button")
        } message: {
            Text("你即将退出“\(group.name)”。退出后该群会话会从你的列表移除。")
        }
    }
}

struct GroupDissolveConfirmSheet: View {
    let group: GroupInfo
    let preview: RemoteGroupDissolvePreview?
    let isSubmitting: Bool
    let isPreviewLoading: Bool
    let isScopeValid: Bool
    let isPreviewScopeValid: Bool
    let previewErrorMessage: String?
    let actionErrorMessage: String?
    let onRetryPreview: (() -> Void)?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var showFinalConfirmation = false

    init(
        group: GroupInfo,
        preview: RemoteGroupDissolvePreview?,
        isSubmitting: Bool,
        isPreviewLoading: Bool = false,
        isScopeValid: Bool = true,
        isPreviewScopeValid: Bool = true,
        previewErrorMessage: String? = nil,
        actionErrorMessage: String? = nil,
        onRetryPreview: (() -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.group = group
        self.preview = preview
        self.isSubmitting = isSubmitting
        self.isPreviewLoading = isPreviewLoading
        self.isScopeValid = isScopeValid
        self.isPreviewScopeValid = isPreviewScopeValid
        self.previewErrorMessage = previewErrorMessage
        self.actionErrorMessage = actionErrorMessage
        self.onRetryPreview = onRetryPreview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var hasUsablePreview: Bool {
        preview?.groupID == group.id && isPreviewScopeValid
    }

    private var canContinue: Bool {
        hasUsablePreview
            && isScopeValid
            && !isPreviewLoading
            && previewErrorMessage == nil
            && !isSubmitting
    }

    private var memberCount: Int? {
        guard state.shouldShowGroupMemberCount,
              let preview,
              preview.groupID == group.id else { return nil }
        let previewCount = preview.memberCount ?? 0
        return previewCount > 0 ? previewCount : group.effectiveMemberCount
    }

    var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(IMColor.muted.opacity(0.22))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(IMColor.danger))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("解散该群")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text(group.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                        }
                        Spacer()
                    }

                    if isPreviewLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(IMColor.brand)
                            Text("正在读取解散影响范围…")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.76)))
                        .accessibilityIdentifier("group_dissolve_preview_loading")
                    } else if let previewErrorMessage, !previewErrorMessage.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(previewErrorMessage)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(IMColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                            if let onRetryPreview {
                                Button {
                                    guard !isSubmitting, !isPreviewLoading else { return }
                                    onRetryPreview()
                                } label: {
                                    Label("重新读取影响范围", systemImage: "arrow.clockwise")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(IMColor.brand)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(
                                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                                .fill(IMColor.brand.opacity(0.10))
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("group_dissolve_preview_retry_button")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.danger.opacity(0.06)))
                        .accessibilityIdentifier("group_dissolve_preview_error")
                    }

                    if !isScopeValid && !isPreviewLoading {
                        Text("群聊状态、账号或你的群角色已变化，请返回后重试")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_dissolve_scope_error")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("影响范围")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        if let memberCount {
                            GroupDissolveEffectRow(symbol: "person.3.fill", text: "将影响 \(memberCount) 名成员")
                        }
                        GroupDissolveEffectRow(symbol: "bubble.left.and.bubble.right.fill", text: "所有成员的群会话都会从列表移除")
                        GroupDissolveEffectRow(symbol: "folder.fill", text: "群资料、成员、文件和群历史入口将不再可见")
                        GroupDissolveEffectRow(symbol: "bell.badge.fill", text: "原成员会收到个人系统通知")
                    }
                    .plainCard(radius: 22)

                    Text("如果你只是想退出群聊，请先转让群主后再退出。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("解散后不可恢复，请确认是否继续。")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .fixedSize(horizontal: false, vertical: true)

                    if let actionErrorMessage, !actionErrorMessage.isEmpty {
                        Text(actionErrorMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("group_dissolve_action_error")
                    }

                    HStack(spacing: 10) {
                        Button {
                            guard !isSubmitting else { return }
                            onCancel()
                            dismiss()
                        } label: {
                            Text("取消")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(IMColor.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(.white.opacity(0.88))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .opacity(isSubmitting ? 0.62 : 1)
                        .accessibilityIdentifier("group_dissolve_cancel_button")

                        Button(role: .destructive) {
                            guard canContinue else { return }
                            showFinalConfirmation = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(
                                    isPreviewLoading
                                        ? "读取中..."
                                        : (isSubmitting ? "解散中..." : "继续解散")
                                )
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(canContinue ? IMColor.danger : Color(hex: 0xB8C0D8))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canContinue)
                        .accessibilityIdentifier("group_dissolve_continue_button")
                    }
                }
                .padding(18)
            }
        }
        .alert("最终确认解散群聊？", isPresented: $showFinalConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认解散", role: .destructive) {
                guard canContinue else { return }
                onConfirm()
            }
            .accessibilityIdentifier("group_dissolve_final_confirm_button")
        } message: {
            Text("你即将解散“\(group.name)”。所有成员将失去该群会话，且操作不可恢复。")
        }
    }
}

private struct GroupDissolveEffectRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.danger)
                .frame(width: 30, height: 30)
                .background(Circle().fill(IMColor.danger.opacity(0.10)))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IMColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GroupProfileEditSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    @State private var groupName: String
    @State private var groupDescription: String
    @State private var showPhotoPicker = false
    @State private var selectedImage: UIImage?
    @State private var croppedAvatarData: Data?
    @State private var croppedPreview: UIImage?
    @State private var showCropper = false
    @State private var isSaving = false
    @State private var inlineMessage: String?

    private let outputSize = 512

    init(group: GroupInfo) {
        self.group = group
        _groupName = State(initialValue: group.name)
        _groupDescription = State(initialValue: group.groupDescription)
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canSave: Bool {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = groupDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionIsValid = GroupDescriptionInputPolicy.normalizedUnicodeScalarCount(groupDescription)
            <= GroupDescriptionInputPolicy.maximumUnicodeScalars
        let profileChanged = trimmed != currentGroup.name || croppedAvatarData != nil
        let descriptionChanged = normalizedDescription != currentGroup.groupDescription
        return !isSaving && !trimmed.isEmpty && descriptionIsValid && (profileChanged || descriptionChanged)
    }

    var body: some View {
        let avatarPickerTitle = croppedAvatarData == nil ? "选择群头像" : "重新选择群头像"
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(IMColor.muted.opacity(0.22))
                        .frame(width: 42, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                    HStack(spacing: 12) {
                        GroupAvatarView(name: groupName.isEmpty ? currentGroup.name : groupName, seed: 0x5D6BFF, size: 58, imageURL: croppedPreview == nil ? currentGroup.avatarURL : "", avatarVersion: croppedPreview == nil ? currentGroup.avatarVersion : "", avatarUpdatedAt: croppedPreview == nil ? currentGroup.avatarUpdatedAt : "", imageCacheKey: croppedPreview == nil ? state.groupAvatarCacheKey(groupID: currentGroup.id, avatarURL: currentGroup.avatarURL, avatarVersion: currentGroup.avatarVersion, avatarUpdatedAt: currentGroup.avatarUpdatedAt) : "")
                            .overlay {
                                if let croppedPreview {
                                    Image(uiImage: croppedPreview)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(Circle())
                                }
                            }
                            .shadow(color: IMColor.brand.opacity(0.12), radius: 16, y: 8)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("编辑群资料")
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            Text("群名称和头像会同步到会话、群列表与群详情。")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(IMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(IMColor.muted)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.white.opacity(0.76)))
                                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭群资料编辑")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("群名称")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(IMColor.muted)
                        TextField("输入群名称", text: $groupName)
                            .font(.system(size: 17, weight: .bold))
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .imReadableInputText()
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(.white.opacity(0.94))
                                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                            )
                            .accessibilityIdentifier("group_profile_name_input")
                    }
                    .plainCard(radius: 22)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("群描述")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(IMColor.muted)
                            Spacer()
                            Text("\(GroupDescriptionInputPolicy.normalizedUnicodeScalarCount(groupDescription)) / 500")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(GroupDescriptionInputPolicy.normalizedUnicodeScalarCount(groupDescription) > 500 ? IMColor.danger : IMColor.muted)
                                .monospacedDigit()
                        }
                        TextEditor(text: $groupDescription)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(IMColor.ink)
                            .scrollContentBackgroundHiddenCompat()
                            .frame(minHeight: 110)
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(IMColor.line, lineWidth: 1))
                            .accessibilityIdentifier("group_profile_description_input")
                        Text("首尾空白会自动去除；留空保存可清除群描述。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    .plainCard(radius: 22)

                    Button {
                        showPhotoPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(avatarPickerTitle)
                                    .font(.system(size: 16, weight: .black))
                                    .foregroundStyle(IMColor.ink)
                                Text("上传前裁剪为正方形，支持 JPG / PNG / WebP。")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(IMColor.muted.opacity(0.72))
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(.white.opacity(0.92))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.92), lineWidth: 1))
                                .shadow(color: IMColor.brand.opacity(0.08), radius: 18, y: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group_profile_avatar_picker")

                    if let inlineMessage {
                        Text(inlineMessage)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(inlineMessage.contains("成功") ? IMColor.success : IMColor.danger)
                            .padding(.horizontal, 2)
                    }

                    PrimaryButton(title: isSaving ? "保存中..." : "保存群资料", systemImage: "checkmark.circle.fill", disabled: !canSave) {
                        save()
                    }
                    .accessibilityIdentifier("group_profile_save_button")
                }
                .padding(18)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerCompat(selectionLimit: 1, filter: .images) { items in
                guard let data = items.first?.data,
                      let image = UIImage(data: data) else {
                    inlineMessage = "无法读取图片，请重新选择"
                    return
                }
                selectedImage = image.normalizedForGroupAvatarCrop()
                showCropper = true
            }
        }
        .sheet(isPresented: $showCropper, onDismiss: resetCropperSelection) {
            if let selectedImage {
                GroupAvatarCropperSheet(image: selectedImage) {
                    showCropper = false
                    resetCropperSelection()
                } onCropped: { data, preview in
                    croppedAvatarData = data
                    croppedPreview = preview
                    showCropper = false
                    resetCropperSelection()
                }
                .presentationDetentsCompat([.large])
                .presentationCornerRadiusCompat(34)
                .presentationBackgroundClearCompat()
                .interactiveDismissDisabled(true)
            }
        }
    }

    private func resetCropperSelection() {
        selectedImage = nil
    }

    private func save() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            inlineMessage = "请输入群名称"
            return
        }
        guard !isSaving else { return }
        let normalizedDescription: String
        do {
            normalizedDescription = try GroupDescriptionInputPolicy.normalize(groupDescription)
        } catch let error as GroupDescriptionInputError {
            inlineMessage = error.userMessage
            return
        } catch {
            inlineMessage = "群描述格式不正确"
            return
        }
        let profileChanged = trimmedName != currentGroup.name || croppedAvatarData != nil
        let descriptionChanged = normalizedDescription != currentGroup.groupDescription
        isSaving = true
        inlineMessage = nil
        Task {
            var profileOK = true
            if profileChanged {
                profileOK = await state.updateGroupProfile(
                    groupID: currentGroup.id,
                    name: trimmedName,
                    avatarImageData: croppedAvatarData,
                    mimeType: "image/jpeg",
                    width: outputSize,
                    height: outputSize
                )
            }
            guard profileOK else {
                isSaving = false
                inlineMessage = state.toast ?? "群资料保存失败"
                return
            }
            var descriptionOK = true
            if descriptionChanged {
                descriptionOK = await state.updateGroupDescription(
                    groupID: currentGroup.id,
                    rawValue: normalizedDescription
                )
            }
            isSaving = false
            if descriptionOK {
                inlineMessage = "群资料已更新"
                dismiss()
            } else {
                inlineMessage = profileChanged
                    ? "名称或头像已保存，但群描述保存失败；请重试群描述"
                    : (state.toast ?? "群描述保存失败")
            }
        }
    }
}

private struct GroupAvatarCropperSheet: View {
    let image: UIImage
    let onClose: () -> Void
    let onCropped: (Data, UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var inlineMessage: String?

    private let previewSize: CGFloat = 282
    private let outputSize = 512
    private let scaleRange: ClosedRange<CGFloat> = 1...4

    private var scaleBinding: Binding<CGFloat> {
        Binding(
            get: { scale },
            set: { updateScale($0, syncGestureBaseline: true) }
        )
    }

    var body: some View {
        ZStack {
            AuroraBackground()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

            VStack(spacing: 18) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.22))
                    .frame(width: 42, height: 5)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("裁剪群头像")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text("拖动图片调整位置，双指缩放为圆形头像。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                    }
                    Spacer()
                    Button {
                        onClose()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.72)))
                            .overlay(Circle().stroke(IMColor.line.opacity(0.9), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭群头像裁剪")
                }

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: previewSize, height: previewSize)
                        .clipShape(Circle())
                        .gesture(dragGesture.simultaneously(with: magnifyGesture))
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: previewSize, height: previewSize)
                        .shadow(color: IMColor.brand.opacity(0.18), radius: 18, y: 8)
                    Circle()
                        .stroke(IMColor.brand.opacity(0.28), lineWidth: 1)
                        .frame(width: previewSize + 8, height: previewSize + 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                Slider(value: scaleBinding, in: scaleRange) {
                    Text("缩放")
                }
                .tint(IMColor.brand)

                if let inlineMessage {
                    Text(inlineMessage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PrimaryButton(title: "使用此头像", systemImage: "checkmark.circle.fill") {
                    guard let result = croppedAvatar() else {
                        inlineMessage = "头像裁剪失败，请重新选择图片"
                        return
                    }
                    onCropped(result.data, result.preview)
                    dismiss()
                }
            }
            .padding(18)
        }
        .onAppear {
            clampCropState(syncGestureBaseline: true)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampedOffset(proposed, scale: scale)
            }
            .onEnded { _ in
                clampCropState(syncGestureBaseline: true)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                updateScale(lastScale * value, syncGestureBaseline: false)
            }
            .onEnded { _ in
                clampCropState(syncGestureBaseline: true)
            }
    }

    private func updateScale(_ proposedScale: CGFloat, syncGestureBaseline: Bool) {
        let nextScale = AvatarCropBounds.clampedScale(proposedScale, range: scaleRange)
        scale = nextScale
        offset = clampedOffset(offset, scale: nextScale)
        if syncGestureBaseline {
            lastScale = nextScale
            lastOffset = offset
        }
    }

    private func clampCropState(syncGestureBaseline: Bool) {
        scale = AvatarCropBounds.clampedScale(scale, range: scaleRange)
        offset = clampedOffset(offset, scale: scale)
        if syncGestureBaseline {
            lastScale = scale
            lastOffset = offset
        }
    }

    private func clampedOffset(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        AvatarCropBounds.clampedOffset(
            imageSize: image.normalizedForGroupAvatarCrop().size,
            previewSize: previewSize,
            scale: scale,
            proposed: proposed
        )
    }

    private func croppedAvatar() -> (data: Data, preview: UIImage)? {
        let normalized = image.normalizedForGroupAvatarCrop()
        let imageSize = normalized.size
        let safeScale = AvatarCropBounds.clampedScale(scale, range: scaleRange)
        let safeOffset = AvatarCropBounds.clampedOffset(imageSize: imageSize, previewSize: previewSize, scale: safeScale, proposed: offset)
        let baseScale = max(previewSize / imageSize.width, previewSize / imageSize.height)
        let totalScale = max(baseScale * safeScale, 0.0001)
        let cropSide = min(imageSize.width, imageSize.height, previewSize / totalScale)
        var originX = imageSize.width / 2 - safeOffset.width / totalScale - cropSide / 2
        var originY = imageSize.height / 2 - safeOffset.height / totalScale - cropSide / 2
        originX = min(max(originX, 0), imageSize.width - cropSide)
        originY = min(max(originY, 0), imageSize.height - cropSide)
        let cropRect = CGRect(x: originX * normalized.scale, y: originY * normalized.scale, width: cropSide * normalized.scale, height: cropSide * normalized.scale)
        guard let cgImage = normalized.cgImage?.cropping(to: cropRect) else { return nil }
        let cropped = UIImage(cgImage: cgImage, scale: normalized.scale, orientation: .up)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        let square = renderer.image { _ in
            cropped.draw(in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        }
        var quality: CGFloat = 0.88
        var data = square.jpegData(compressionQuality: quality)
        while let current = data, current.count > 2 * 1024 * 1024, quality > 0.55 {
            quality -= 0.08
            data = square.jpegData(compressionQuality: quality)
        }
        guard let data else { return nil }
        return (data, square)
    }
}

private extension UIImage {
    func normalizedForGroupAvatarCrop() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

enum GroupMemberInviteAffordancePolicy {
    static func isVisible(canManage: Bool, inviteConfirmRequired: Bool) -> Bool {
        canManage || inviteConfirmRequired
    }
}

struct GroupMemberManagementView: View {
    let groupID: String
    @EnvironmentObject private var state: AppState
    @State private var selectedMember: IMUser?
    @State private var pendingProfileMember: IMUser?
    @State private var profileMember: IMUser?
    @State private var selectedConversationRoute: ContactsConversationRoute?
    @State private var pendingProfileConversationID: String?
    @State private var showInvitePicker = false
    @State private var memberFilter = ""

    private var group: GroupInfo {
        state.group(id: groupID) ?? GroupInfo(id: groupID, name: "群成员", notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
    }

    private var canManage: Bool {
        state.canManageGroup(group)
    }

    private var canInviteMembers: Bool {
        GroupMemberInviteAffordancePolicy.isVisible(
            canManage: canManage,
            inviteConfirmRequired: group.inviteConfirmRequired
        )
    }

    private var ownerUser: IMUser? {
        guard let owner = ownerIdentityUser else { return nil }
        let selfKeys = ownerStableKeys(for: state.currentUser)
        guard !ownerStableKeys(for: owner).isDisjoint(with: selfKeys) else { return owner }
        let projection = state.myGroupMemberProjection(groupID: group.id)
            ?? (group.members + group.admins).first { member in
                !ownerStableKeys(for: member).isDisjoint(with: selfKeys)
            }
        guard let projection else { return owner }
        return owner.withName(GroupMemberDisplayNameResolver.projectedName(for: projection))
    }

    private var ownerIdentityUser: IMUser? {
        let ownerID = group.ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownerID.isEmpty {
            if ownerIDMatches(state.currentUser, ownerID: ownerID) {
                return state.currentUser
            }
            return ownerCandidateUsers.first { ownerIDMatches($0, ownerID: ownerID) }
        }

        let ownerName = group.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ownerName.isEmpty else { return nil }
        let nameMatches = ownerCandidateUsers.filter { user in
            user.name.trimmingCharacters(in: .whitespacesAndNewlines) == ownerName
        }
        return nameMatches.count == 1 ? nameMatches.first : nil
    }

    private var ownerCandidateUsers: [IMUser] {
        var seen = Set<String>()
        return ([state.currentUser] + group.members + group.admins).filter { user in
            let key = ownerStableKey(for: user)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func ownerIDMatches(_ user: IMUser, ownerID: String) -> Bool {
        ownerStableKeys(for: user).contains(ownerID)
    }

    private func ownerStableKeys(for user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private func ownerStableKey(for user: IMUser) -> String {
        for key in [user.id, user.userID, user.username] {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private var filteredOwnerUser: IMUser? {
        guard let ownerUser else { return nil }
        return matchesFilter(ownerUser, role: .owner) ? ownerUser : nil
    }

    private var adminUsers: [IMUser] {
        group.admins.filter { user in
            !state.isGroupOwner(user, in: group)
        }
    }

    private var filteredAdminUsers: [IMUser] {
        filteredUsers(adminUsers, role: .admin)
    }

    private var memberUsers: [IMUser] {
        group.members.filter { user in
            !state.isGroupOwner(user, in: group) && !state.isGroupAdmin(user, in: group)
        }
    }

    private var filteredMemberUsers: [IMUser] {
        filteredUsers(memberUsers, role: .member)
    }

    private var hasActiveFilter: Bool {
        !IMUserSearchMatcher.normalized(memberFilter).isEmpty
    }

    private var hasFilteredMatches: Bool {
        filteredOwnerUser != nil || !filteredAdminUsers.isEmpty || !filteredMemberUsers.isEmpty
    }

    private func matchesFilter(_ user: IMUser, role: GroupMemberRole) -> Bool {
        IMUserSearchMatcher.matches(
            user: user.withName(GroupMemberDisplayNameResolver.projectedName(for: user)),
            role: role.title,
            query: memberFilter
        )
    }

    private func filteredUsers(_ users: [IMUser], role: GroupMemberRole) -> [IMUser] {
        let query = memberFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return users }
        return users
            .compactMap { user -> (user: IMUser, score: Int, name: String)? in
                let name = GroupMemberDisplayNameResolver.projectedName(for: user)
                guard let score = IMUserSearchMatcher.matchScore(
                    user: user.withName(name),
                    role: role.title,
                    query: query
                ) else { return nil }
                return (user, score, name)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.user)
    }

    private func loadMoreMembersIfNeeded(appearing user: IMUser, in users: [IMUser]) {
        guard !hasActiveFilter, group.membersPartial else { return }
        let userKeys = ownerStableKeys(for: user)
        let preloadWindow = users.suffix(8)
        guard preloadWindow.contains(where: { candidate in
            let candidateKeys = ownerStableKeys(for: candidate)
            return !candidateKeys.isDisjoint(with: userKeys)
        }) else { return }
        state.loadNextGroupMembersPageIfNeeded(groupID: group.id)
    }

    private func openPendingProfileConversationIfNeeded() {
        guard let conversationID = pendingProfileConversationID else { return }
        pendingProfileConversationID = nil
        DispatchQueue.main.async {
            selectedConversationRoute = ContactsConversationRoute(id: conversationID)
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(symbol: "person.3.fill", title: "群成员", subtitle: canManage ? "查看群主、管理员和成员。点按成员可查看资料或管理权限。" : "查看群主、管理员和成员。点按成员可查看资料。", showsCloseButton: true)
                        GroupMemberStatsCard(group: group, ownerName: ownerUser?.name ?? group.owner)

                        if canInviteMembers {
                            PrimaryButton(title: "邀请好友入群", systemImage: "person.badge.plus") {
                                showInvitePicker = true
                            }
                            .accessibilityIdentifier("group_member_invite_button")
                        }

                        SearchField(text: $memberFilter, placeholder: "快速筛选姓名、账号、用户ID、手机号或拼音")

                        if hasActiveFilter, !hasFilteredMatches {
                            EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有匹配的成员", subtitle: "试试姓名、用户ID、角色或拼音首字母。")
                        }

                        if let ownerUser = filteredOwnerUser {
                            GroupMemberSection(title: "群主") {
		                                GroupMemberRoleRow(user: ownerUser, role: .owner) {
		                                    selectedMember = ownerUser
		                                }
                                    .onAppear {
                                        loadMoreMembersIfNeeded(appearing: ownerUser, in: ownerCandidateUsers)
                                    }
                            }
                        }

                        if !filteredAdminUsers.isEmpty {
                            GroupMemberSection(title: "管理员") {
                                ForEach(filteredAdminUsers) { user in
		                                    GroupMemberRoleRow(user: user, role: .admin) {
		                                        selectedMember = user
		                                    }
                                        .onAppear {
                                            loadMoreMembersIfNeeded(appearing: user, in: filteredAdminUsers)
                                        }
                                }
                            }
                        }

                        if !hasActiveFilter || !filteredMemberUsers.isEmpty {
	                        GroupMemberSection(title: "成员") {
	                            if filteredMemberUsers.isEmpty {
                                Text("暂无普通成员")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.72)))
	                            } else {
	                                ForEach(filteredMemberUsers) { user in
		                                    GroupMemberRoleRow(user: user, role: .member) {
		                                        selectedMember = user
		                                    }
                                        .onAppear {
                                            loadMoreMembersIfNeeded(appearing: user, in: filteredMemberUsers)
                                        }
		                                }
		                            }
		                        }
                        }
	                    }
                    .padding(18)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedMember, onDismiss: {
                guard let pendingProfileMember else { return }
                self.pendingProfileMember = nil
                DispatchQueue.main.async {
                    profileMember = pendingProfileMember
                }
            }) { user in
                GroupMemberActionSheet(groupID: group.id, user: user) { profileUser in
                    pendingProfileMember = profileUser
                    selectedMember = nil
                }
                    .presentationDetentsCompat([.height(520), .medium])
                    .presentationDragIndicatorCompat(.hidden)
                    .presentationCornerRadiusCompat(34)
                    .presentationBackgroundClearCompat()
            }
                .sheet(item: $profileMember, onDismiss: {
                    openPendingProfileConversationIfNeeded()
                }) { user in
                    NavigationStackCompat {
                        UserProfileView(user: user, onOpenConversation: { conversationID in
                            pendingProfileConversationID = conversationID
                            profileMember = nil
                        })
                    }
                .presentationDetentsCompat([.large])
                .presentationDragIndicatorCompat(.visible)
            }
            // JHT_MOD_BEGIN CONTACT_CHAT_BLANK_FIX_MEMBER_DESTINATION - 修改开始：群成员页聊天页目标读取 route conversationID
            .navigationDestinationCompat(item: $selectedConversationRoute) { route in
                ChatView(conversationID: route.conversationID)
            }
            // JHT_MOD_END CONTACT_CHAT_BLANK_FIX_MEMBER_DESTINATION - 修改结束
            .sheet(isPresented: $showInvitePicker) {
                GroupInviteMembersSheet(group: group)
                    .presentationDetentsCompat([.medium, .large])
            }
            .onAppear {
                state.loadGroupDetailIfNeeded(groupID: groupID, force: true)
                state.loadNextGroupMembersPageIfNeeded(groupID: groupID)
            }
        }
    }
}

private enum GroupMemberRole {
    case owner
    case admin
    case member

    var title: String {
        switch self {
        case .owner: "群主"
        case .admin: "管理员"
        case .member: "成员"
        }
    }

    var symbol: String {
        switch self {
        case .owner: "crown.fill"
        case .admin: "checkmark.shield.fill"
        case .member: "person.fill"
        }
    }

    var color: Color {
        switch self {
        case .owner: IMColor.warning
        case .admin: IMColor.brand
        case .member: IMColor.muted
        }
    }
}

private struct GroupMemberStatsCard: View {
    let group: GroupInfo
    let ownerName: String
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if let memberCount = state.visibleGroupMemberCount(group.memberCount, group.members.count) {
                GroupMemberStat(value: String(memberCount), label: "成员")
            }
            GroupMemberStat(value: ownerName, label: "群主")
            GroupMemberStat(value: "\(group.admins.count)", label: "管理员")
        }
        .plainCard(radius: 22)
    }
}

private struct GroupMemberStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.brand.opacity(0.06)))
    }
}

private struct GroupMemberSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 4)
            VStack(spacing: 10) {
                content
            }
        }
    }
}

private struct GroupMemberRoleRow: View {
    @EnvironmentObject private var state: AppState

    let user: IMUser
    let role: GroupMemberRole
    let action: () -> Void

    private var userIDText: String {
        let value = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? user.id : value
    }

    private var displayName: String {
        GroupMemberDisplayNameResolver.projectedName(for: user)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: displayName, seed: user.avatarSeed, size: 50, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(IMColor.ink)
                            .lineLimit(1)
                        CertificationPillView(
                            exactUID: user.id,
                            compact: true
                        )
                        if role != .member {
                            GroupRoleBadge(role: role)
                        }
                    }
                    CopyableUserIDText(
                        value: userIDText,
                        prefix: "用户ID：",
                        font: .system(size: 11, weight: .semibold),
                        color: IMColor.muted
                    )
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.75))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(role == .owner ? 0.96 : 0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(role == .owner ? IMColor.warning.opacity(0.32) : IMColor.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct GroupRoleBadge: View {
    let role: GroupMemberRole

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: role.symbol)
                .font(.system(size: 10, weight: .black))
            Text(role.title)
                .font(.system(size: 11, weight: .black))
        }
        .foregroundStyle(role.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(role.color.opacity(0.12)))
    }
}

private struct GroupMemberActionSheet: View {
    let groupID: String
    let user: IMUser
    let onViewProfile: (IMUser) -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveConfirm = false
    @State private var showTransferConfirm = false

    private var group: GroupInfo {
        state.group(id: groupID) ?? GroupInfo(id: groupID, name: "群成员", notice: "", owner: "", members: [], admins: [], muted: false, allMuted: false)
    }

    private var role: GroupMemberRole {
        if state.isGroupOwner(user, in: group) {
            return .owner
        }
        if state.isGroupAdmin(user, in: group) {
            return .admin
        }
        return .member
    }

    private var userIDText: String {
        let value = user.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? user.id : value
    }

    private var displayName: String {
        GroupMemberDisplayNameResolver.projectedName(for: user)
    }

    private var isCurrentUserOwner: Bool {
        group.isCurrentUserOwner || state.isGroupOwner(state.currentUser, in: group)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 14) {
                Capsule()
                    .fill(IMColor.muted.opacity(0.24))
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    AvatarView(name: displayName, seed: user.avatarSeed, size: 54, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(displayName)
                                .font(.system(size: 20, weight: .black))
                                .foregroundStyle(IMColor.ink)
                            CertificationPillView(
                                exactUID: user.id,
                                compact: true
                            )
                            GroupRoleBadge(role: role)
                        }
                        Text(group.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        CopyableUserIDText(
                            value: userIDText,
                            prefix: "用户ID：",
                            font: .system(size: 11, weight: .semibold),
                            color: IMColor.muted
                        )
                    }
                    Spacer()
                    IconButton(symbol: "xmark", tint: IMColor.muted) {
                        dismiss()
                    }
                }

                actionContent
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .shadow(color: IMColor.brand.opacity(0.13), radius: 24, y: 10)
            )
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .alert("移出群聊？", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) {}
            Button("移出", role: .destructive) {
                state.removeGroupMember(groupID: groupID, userID: user.id)
                dismiss()
            }
        } message: {
            Text("移出后，\(displayName) 将无法继续查看该群的新消息。")
        }
        .alert("转让群主？", isPresented: $showTransferConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认转让", role: .destructive) {
                Task {
                    if await state.transferGroupOwner(groupID: groupID, targetUID: user.id) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("\(displayName) 将成为群主，你将变为普通成员。此操作会立即同步给群成员。")
        }
    }

    private var actionContent: some View {
        VStack(spacing: 10) {
            GroupMemberActionRow(symbol: "person.crop.circle.fill", title: "查看资料", subtitle: "查看成员资料与可用操作", tint: IMColor.brand) {
                onViewProfile(user)
            }

            if role != .owner, isCurrentUserOwner {
                GroupMemberActionRow(
                    symbol: "crown.fill",
                    title: state.isGroupOwnerTransferMutating(groupID) ? "转让中..." : "转让群主",
                    subtitle: "目标成为群主，你降为普通成员",
                    tint: IMColor.warning
                ) {
                    showTransferConfirm = true
                }
                .disabled(state.isGroupOwnerTransferMutating(groupID))
                .accessibilityIdentifier("group_owner_transfer_\(user.id)")
            }

            if role == .owner {
                GroupMemberActionRow(symbol: "crown.fill", title: "群主身份不可调整", subtitle: "群主保留最高管理权限", tint: IMColor.warning) {}
                    .disabled(true)
                    .opacity(0.74)
            } else if role == .admin, isCurrentUserOwner {
                GroupMemberActionRow(symbol: "person.crop.circle.badge.minus", title: "设为普通成员", subtitle: "取消管理员权限，仍保留群成员身份", tint: IMColor.brand) {
                    state.setGroupMemberAdmin(groupID: groupID, userID: user.id, isAdmin: false)
                    dismiss()
                }
            } else if role == .member, isCurrentUserOwner {
                GroupMemberActionRow(symbol: "checkmark.shield.fill", title: "设为管理员", subtitle: "允许管理成员、公告和成员审批", tint: IMColor.brand) {
                    state.setGroupMemberAdmin(groupID: groupID, userID: user.id, isAdmin: true)
                    dismiss()
                }
            } else {
                GroupMemberActionRow(symbol: "checkmark.shield.fill", title: "成员权限", subtitle: "仅群主可以调整管理员身份", tint: IMColor.muted) {}
                    .disabled(true)
                    .opacity(0.74)
            }

            if role != .owner, state.canManageGroup(group) {
                GroupMemberActionRow(symbol: "person.crop.circle.badge.xmark", title: "移出群聊", subtitle: "需要二次确认后生效", tint: IMColor.danger) {
                    showRemoveConfirm = true
                }
            }
        }
    }
}

private struct GroupMemberActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(tint == IMColor.danger ? IMColor.danger : IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.7))
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0xF6F8FD)))
        }
        .buttonStyle(.plain)
    }
}

private struct GroupInviteMembersSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var isSubmitting = false

    private var candidateUsers: [IMUser] {
        let existingIDs = Set(group.members.map(\.id))
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.inviteCandidates(for: group).filter { user in
            !existingIDs.contains(user.id) &&
            !user.isCancelledUser &&
            (trimmedQuery.isEmpty || IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: trimmedQuery
            ))
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(symbol: "person.badge.plus", title: "邀请好友", subtitle: state.canManageGroup(group) ? "群主和管理员可邀请已知企业成员，成功后直接入群。" : "普通成员邀请好友后，需要群主或管理员审核。", showsCloseButton: true)
                    SearchField(text: $query, placeholder: state.canManageGroup(group) ? "搜索成员、用户ID或拼音" : "搜索好友、用户ID或拼音")
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if candidateUsers.isEmpty {
                                EmptyStateView(symbol: "person.crop.circle.badge.checkmark", title: "没有可邀请成员", subtitle: "当前好友均已在群内，或换个关键词搜索。")
                            } else {
                                ForEach(candidateUsers) { user in
                                    let displayName = state.remarkPreferredDisplayName(for: user)
                                    Button {
                                        if selectedIDs.contains(user.id) {
                                            selectedIDs.remove(user.id)
                                        } else {
                                            selectedIDs.insert(user.id)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
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
                                }
                            }
                        }
                    }
                    PrimaryButton(title: selectedIDs.isEmpty ? "邀请入群" : (state.canManageGroup(group) ? "邀请入群 \(selectedIDs.count)" : "提交审核 \(selectedIDs.count)"), systemImage: "paperplane.fill", disabled: selectedIDs.isEmpty || isSubmitting) {
                        submit()
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let ok = await state.inviteGroupMembers(groupID: group.id, memberIDs: Array(selectedIDs))
            isSubmitting = false
            if ok {
                dismiss()
            }
        }
    }
}

private struct GroupQRCodeSheet: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(symbol: "qrcode", title: "群二维码", subtitle: "二维码有效期 7 天，入群申请仍需管理员审批。", showsCloseButton: true)
                VStack(spacing: 14) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 86, weight: .regular))
                        .foregroundStyle(IMColor.brand)
                        .frame(width: 174, height: 174)
                        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(IMColor.brand.opacity(0.08)))
                    Text(group.name)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text("邀请码 BS-\(group.id.uppercased())")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                .frame(maxWidth: .infinity)
                .plainCard(radius: 26)

                HStack(spacing: 10) {
                    GroupSheetActionButton(title: "复制链接", symbol: "doc.on.doc.fill") {
                        state.toast = "群邀请链接已复制"
                    }
                    GroupSheetActionButton(title: "刷新二维码", symbol: "arrow.clockwise") {
                        state.toast = "群二维码已刷新"
                    }
                }
            }
            .padding(18)
        }
    }
}

enum GroupFilePreviewPolicy {
    static func inAppDestination(for file: FileItem) -> FileItem? {
        file.previewAvailable ? file : nil
    }
}

private struct GroupFilesSheet: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    @State private var selectedFile: FileItem?
    @State private var shareItem: FileShareItem?
    @State private var forwardingFile: FileItem?
    @State private var downloadingFileID: String?

    private var groupFiles: [FileItem] {
        state.files(for: group.id)
    }

    private var canManage: Bool {
        state.canManageGroup(group)
    }

    private var isSyncing: Bool {
        state.isGroupFileSyncing(groupID: group.id)
    }

    private var syncError: String? {
        state.groupFileSyncError(groupID: group.id)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(symbol: "folder.fill", title: "群文件", subtitle: "预览、下载和转发群内文件。", showsCloseButton: true)
                    if isSyncing && groupFiles.isEmpty {
                        RemoteLoadingStateView(
                            title: "正在同步群文件",
                            subtitle: "正在从企业文件服务拉取当前群可见文件。"
                        )
                    } else if let syncError, groupFiles.isEmpty {
                        EmptyStateView(symbol: "wifi.exclamationmark", title: "群文件同步失败", subtitle: syncError)
                        PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                            state.refreshGroupFiles(groupID: group.id, silent: false)
                        }
                    } else if groupFiles.isEmpty {
                        EmptyStateView(symbol: "folder.badge.questionmark", title: "暂无群文件", subtitle: "群成员上传的文件会在这里展示。")
	                    } else {
                        if isSyncing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.72)
                                Text("正在刷新群文件")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                Spacer()
                            }
                            .plainCard(radius: 18)
                        }
	                        ForEach(groupFiles) { file in
	                            VStack(alignment: .leading, spacing: 14) {
                                Button {
                                    openGroupFilePreview(file)
                                } label: {
                                    HStack(spacing: 12) {
                                        AvatarView(name: file.type, seed: file.accentHex, size: 48)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.name)
                                                .font(.system(size: 16, weight: .black))
                                                .foregroundStyle(IMColor.ink)
                                                .lineLimit(1)
                                            Text("\(file.size) · \(file.owner) · \(file.time)")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        StatusPill(title: file.type, color: IMColor.brand)
                                    }
                                }
                                .buttonStyle(.plain)
		                                HStack(spacing: 8) {
		                                    GroupSheetActionButton(title: "预览", symbol: "eye.fill") {
                                                openGroupFilePreview(file)
		                                    }
			                                    GroupSheetActionButton(title: "下载", symbol: "arrow.down.circle.fill") {
                                                if file.downloadAvailable {
                                                    prepareGroupFileForSharing(file)
                                                } else {
                                                    state.toast = "该文件暂未开放下载"
                                                }
	                                    }
	                                    GroupSheetActionButton(title: "转发", symbol: "arrowshape.turn.up.right.fill") {
	                                        forwardingFile = file
	                                    }
	                                }
                            }
                            .plainCard(radius: 22)
                        }
                    }
                }
                .padding(18)
	            }
		        }
		            .sheet(item: $selectedFile) { file in
		                FilePreviewView(file: file)
		                    .presentationDetentsCompat([.large])
		            }
                    .sheet(item: $shareItem) { item in
                        FileActivityView(activityItems: [item.url])
                            .presentationDetentsCompat([.medium, .large])
                    }
                    .sheet(item: $forwardingFile) { file in
                        GroupFileForwardTargetSheet(file: file) {
                            forwardingFile = nil
                        }
                        .presentationDetentsCompat([.large])
                    }
	                .onAppear {
	                    state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
	                }
			    }

    private func openGroupFilePreview(_ file: FileItem) {
        if let destination = GroupFilePreviewPolicy.inAppDestination(for: file) {
            selectedFile = destination
        } else {
            state.toast = "该文件暂不支持在线预览"
        }
    }

    private func prepareGroupFileForSharing(_ file: FileItem) {
        guard downloadingFileID == nil else { return }
        downloadingFileID = file.id
        state.toast = "正在准备下载文件"
        let cacheScope = state.contentCacheScopeKey
        Task {
            do {
                let localURL = try await TenantFileSharePreparer.prepare(file: file, state: state, scope: cacheScope)
                await MainActor.run {
                    guard state.contentCacheScopeKey == cacheScope else {
                        downloadingFileID = nil
                        return
                    }
                    downloadingFileID = nil
                    shareItem = FileShareItem(url: localURL)
                    state.toast = "文件已准备好，可保存或分享"
                }
            } catch {
                await MainActor.run {
                    downloadingFileID = nil
                    state.toast = "文件下载失败，请稍后重试"
                }
            }
        }
    }
			}

private struct GroupFileForwardTargetSheet: View {
    @EnvironmentObject private var state: AppState
    let file: FileItem
    let onComplete: () -> Void
    @State private var query = ""
    @State private var selectedTab: BatchForwardTargetTab = .friend
    @State private var submittingTargetID: String?

    private var candidates: [BatchForwardTargetCandidate] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.batchForwardTargetCandidates().filter { candidate in
            guard candidate.target.tab == selectedTab else { return false }
            guard !normalized.isEmpty else { return true }
            return ([candidate.target.displayName, candidate.subtitle] + candidate.target.searchTerms)
                .contains { $0.lowercased().contains(normalized) }
        }
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(symbol: "arrowshape.turn.up.right.fill", title: "转发文件", subtitle: file.name, showsCloseButton: true)
                    Picker("目标类型", selection: $selectedTab) {
                        Text("好友").tag(BatchForwardTargetTab.friend)
                        Text("群聊").tag(BatchForwardTargetTab.group)
                    }
                    .pickerStyle(.segmented)
                    SearchField(text: $query, placeholder: "搜索目标会话") {}
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(candidates) { candidate in
                                let certificationUID = targetCertificationUID(for: candidate)
                                Button {
                                    guard submittingTargetID == nil else { return }
                                    submittingTargetID = candidate.id
                                    Task {
                                        let succeeded = await state.forwardTenantFile(file, to: candidate.target)
                                        await MainActor.run {
                                            submittingTargetID = nil
                                            if succeeded { onComplete() }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        AvatarView(
                                            name: candidate.target.displayName,
                                            seed: candidate.avatarSeed,
                                            size: 44,
                                            imageURL: candidate.avatarURL,
                                            avatarVersion: candidate.avatarVersion,
                                            avatarUpdatedAt: candidate.avatarUpdatedAt,
                                            certification: certificationUID.flatMap {
                                                state.certificationPresentation(forExactUID: $0)
                                            }
                                        )
                                        .task(id: "\(certificationUID ?? "")|\(state.certificationPresentationScopeRevision)") {
                                            guard let certificationUID else { return }
                                            state.ensureCertificationPresentations(forExactUIDs: [certificationUID])
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(candidate.target.displayName)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(IMColor.ink)
                                            Text(candidate.subtitle)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(IMColor.muted)
                                        }
                                        Spacer()
                                        if submittingTargetID == candidate.id {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "paperplane.fill").foregroundStyle(IMColor.brand)
                                        }
                                    }
                                    .padding(12)
                                    .plainCard(radius: 18)
                                }
                                .buttonStyle(.plain)
                                .disabled(submittingTargetID != nil)
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func targetCertificationUID(for candidate: BatchForwardTargetCandidate) -> String? {
        guard candidate.target.tab == .friend else { return nil }
        // Candidates already carry canonical actor:peer channel IDs. Never
        // decorate a group, an ambiguous channel, or the current user's slot.
        let parts = candidate.target.channelID.split(separator: ":").map(String.init)
        guard parts.count == 2,
              parts.filter({ state.isCurrentUserIdentity($0) }).count == 1,
              let peerUID = parts.first(where: { !state.isCurrentUserIdentity($0) }) else {
            return nil
        }
        return peerUID
    }
}

private struct GroupMuteListSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var showAddMember = false
    @State private var pendingRemoval: GroupMuteListItem?

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canManage: Bool {
        accessMode == .manage
    }

    private var accessMode: GroupMuteListAccessMode {
        GroupMuteListAccessMode(canManage: state.canManageGroupMuteList(currentGroup))
    }

    private var items: [GroupMuteListItem] {
        state.groupMuteListItems(for: currentGroup.id)
    }

    private func displayName(for item: GroupMuteListItem) -> String {
        state.remarkPreferredDisplayName(
            identifiers: [item.targetUID, item.targetUserID, item.targetUsername],
            candidates: [item.targetNickname],
            fallback: item.targetDisplayName
        )
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(
                        symbol: "person.crop.circle.badge.exclamationmark.fill",
                        title: "禁言名单",
                        subtitle: canManage ? "名单成员不能在该群发送消息、附件或表情回应。" : "仅群主或管理员可查看和管理。",
                        showsCloseButton: true
                    )

                    if canManage {
                        PrimaryButton(
                            title: "添加禁言成员",
                            systemImage: "person.badge.minus",
                            disabled: state.groupMuteListCandidateMembers(for: currentGroup.id).isEmpty
                        ) {
                            showAddMember = true
                        }
                        .accessibilityIdentifier("group_mute_list_add_button")
                    }

                    if let error = state.groupMuteListErrorMessage(for: currentGroup.id), !items.isEmpty {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(IMColor.warning)
                            Text(error)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("重试") {
                                state.loadGroupMuteList(groupID: currentGroup.id, force: true)
                            }
                            .font(.system(size: 12, weight: .black))
                            .buttonStyle(.bordered)
                            .tint(IMColor.warning)
                            .accessibilityIdentifier("group_mute_list_retry_button")
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IMColor.warning.opacity(0.10)))
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if state.isGroupMuteListLoading(groupID: currentGroup.id), items.isEmpty {
                                ProgressView("正在同步禁言名单")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            } else if !canManage {
                                EmptyStateView(symbol: "lock.shield.fill", title: "无权限查看", subtitle: "禁言名单仅群主或管理员可查看。")
                            } else if let error = state.groupMuteListErrorMessage(for: currentGroup.id) {
                                EmptyStateView(
                                    symbol: "wifi.exclamationmark",
                                    title: "禁言名单同步失败",
                                    subtitle: error
                                )
                                PrimaryButton(title: "重试同步", systemImage: "arrow.clockwise") {
                                    state.loadGroupMuteList(groupID: currentGroup.id, force: true)
                                }
                                .accessibilityIdentifier("group_mute_list_retry_button")
                            } else if items.isEmpty {
                                EmptyStateView(symbol: "speaker.wave.2.fill", title: "暂无禁言成员", subtitle: "添加后，成员将不能在该群发送文本、附件或表情回应。")
                            } else {
                                ForEach(items) { item in
                                    GroupMuteListRow(
                                        item: item,
                                        isMutating: state.isGroupMuteListMutating(groupID: currentGroup.id, targetUID: item.targetUID)
                                    ) {
                                        pendingRemoval = item
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .refreshable {
                        state.loadGroupMuteList(groupID: currentGroup.id, force: true)
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showAddMember) {
            GroupMuteMemberPickerSheet(groupID: currentGroup.id)
                .presentationDetentsCompat([.medium, .large])
                .presentationDragIndicatorCompat(.visible)
        }
        .alert(item: $pendingRemoval) { item in
            Alert(
                title: Text("解除禁言？"),
                message: Text("确认将 \(displayName(for: item)) 从禁言名单移除。"),
                primaryButton: .destructive(Text("解除禁言")) {
                    Task {
                        await state.removeGroupMuteListMember(groupID: currentGroup.id, targetUID: item.targetUID)
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear {
            guard accessMode.loadsRemoteList else { return }
            state.loadGroupDetailIfNeeded(groupID: currentGroup.id, force: true)
            state.loadGroupMuteList(groupID: currentGroup.id, force: true)
            state.loadNextGroupMembersPageIfNeeded(groupID: currentGroup.id)
        }
        .accessibilityIdentifier("group_mute_list_sheet")
    }
}

private struct GroupMuteListRow: View {
    @EnvironmentObject private var state: AppState

    let item: GroupMuteListItem
    let isMutating: Bool
    let onRemove: () -> Void

    private var displayName: String {
        state.remarkPreferredDisplayName(
            identifiers: [item.targetUID, item.targetUserID, item.targetUsername],
            candidates: [item.targetNickname],
            fallback: item.targetDisplayName
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: displayName, seed: 0xF59E0B, size: 46, imageURL: item.targetAvatarURL, certification: state.certificationPresentation(forExactUID: item.targetUID))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    CertificationPillView(
                        exactUID: item.targetUID,
                        compact: true
                    )
                    StatusPill(title: "已禁言", color: IMColor.warning)
                }
                CopyableUserIDText(
                    value: item.targetDisplayID,
                    prefix: "用户ID：",
                    font: .system(size: 11, weight: .semibold),
                    color: IMColor.muted
                )
                Text("原因：\(item.reasonText)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Text("操作人：\(item.operatorText) · \(item.createdAtText)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                if isMutating {
                    ProgressView()
                        .scaleEffect(0.72)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.warning)
                        .frame(width: 34, height: 34)
                }
            }
            .buttonStyle(.plain)
            .disabled(isMutating)
            .background(Circle().fill(IMColor.warning.opacity(0.12)))
            .accessibilityLabel("解除禁言")
            .accessibilityIdentifier("group_mute_list_remove_\(item.targetUID)")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.72), lineWidth: 1))
    }
}

private struct GroupMuteMemberPickerSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let groupID: String
    @State private var query = ""
    @State private var selectedUser: IMUser?
    @State private var reason = ""
    @State private var isSubmitting = false

    private var candidates: [IMUser] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.groupMuteListCandidateMembers(for: groupID).filter { user in
            trimmedQuery.isEmpty || IMUserSearchMatcher.matches(
                user: user.withName(state.remarkPreferredDisplayName(for: user)),
                query: trimmedQuery
            )
        }
    }

    private var selectedTargetUID: String {
        guard let selectedUser else { return "" }
        let candidates = [selectedUser.id, selectedUser.userID, selectedUser.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                VStack(spacing: 14) {
                    SheetHeader(
                        symbol: "person.badge.minus",
                        title: "添加禁言成员",
                        subtitle: "仅可选择群内普通成员，群主和管理员不会出现在候选列表。",
                        showsCloseButton: true
                    )
                    SearchField(text: $query, placeholder: "搜索成员、用户ID或拼音")
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            if candidates.isEmpty {
                                EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "没有可添加成员", subtitle: "已禁言成员、群主、管理员和注销成员不会出现在这里。")
                            } else {
                                ForEach(candidates) { user in
                                    let displayName = state.remarkPreferredDisplayName(for: user)
                                    Button {
                                        selectedUser = user
                                    } label: {
                                        HStack(spacing: 12) {
                                            AvatarView(name: displayName, seed: user.avatarSeed, size: 46, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certification: state.certificationPresentation(forExactUID: user.id))
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
                                            Image(systemName: selectedUser?.id == user.id ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundStyle(selectedUser?.id == user.id ? IMColor.brand : IMColor.muted.opacity(0.55))
                                        }
                                        .plainCard(radius: 20)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("禁言原因")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                        TextField("可选，便于后续追溯", text: $reason)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.system(size: 14, weight: .bold))
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.86)))
                    }
                    PrimaryButton(
                        title: selectedUser == nil ? "选择成员" : "加入禁言名单",
                        systemImage: "checkmark.circle.fill",
                        disabled: selectedTargetUID.isEmpty || isSubmitting
                    ) {
                        submit()
                    }
                }
                .padding(18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            state.loadNextGroupMembersPageIfNeeded(groupID: groupID)
        }
    }

    private func submit() {
        guard !isSubmitting, !selectedTargetUID.isEmpty else { return }
        isSubmitting = true
        Task {
            let ok = await state.addGroupMuteListMember(groupID: groupID, targetUID: selectedTargetUID, reason: reason)
            isSubmitting = false
            if ok {
                dismiss()
            }
        }
    }
}

private struct GroupMuteAllSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var selectedMode: GroupMuteMode
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var showAlwaysConfirmation = false
    @State private var showCloseConfirmation = false
    @State private var inlineMessage: String?

    init(group: GroupInfo) {
        self.group = group
        let defaultStart = group.allMuteStart ?? Date()
        let defaultEnd = group.allMuteEnd ?? Calendar.current.date(byAdding: .hour, value: 2, to: defaultStart) ?? defaultStart.addingTimeInterval(7200)
        let mode = group.allMuteMode
            ?? (group.allMuted ? (group.allMuteStart == nil && group.allMuteEnd == nil ? .always : .scheduled) : .off)
        _selectedMode = State(initialValue: mode == .off ? .always : mode)
        _startAt = State(initialValue: defaultStart)
        _endAt = State(initialValue: defaultEnd)
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var normalizedEndAt: Date {
        let calendar = Calendar.current
        let baseDay = calendar.startOfDay(for: startAt)
        let endTime = calendar.dateComponents([.hour, .minute], from: endAt)
        var components = calendar.dateComponents([.year, .month, .day], from: baseDay)
        components.hour = endTime.hour
        components.minute = endTime.minute
        let calculated = calendar.date(from: components) ?? endAt
        if calculated <= startAt {
            return calendar.date(byAdding: .day, value: 1, to: calculated) ?? calculated
        }
        return calculated
    }

    private var endsOnNextDay: Bool {
        !Calendar.current.isDate(startAt, inSameDayAs: normalizedEndAt)
    }

    private var schedulePreview: String {
        var previewGroup = currentGroup
        previewGroup.allMuted = true
        previewGroup.allMuteMode = .scheduled
        previewGroup.allMuteActive = nil
        previewGroup.allMuteServerTime = Date()
        previewGroup.allMuteStart = startAt
        previewGroup.allMuteEnd = normalizedEndAt
        return previewGroup.allMuteTimeRangeText()
    }

    private var isSubmitting: Bool {
        state.isGroupMuteMutating(currentGroup.id)
    }

    private var canCloseMute: Bool {
        currentGroup.allMuted
            || currentGroup.allMuteMode != nil && currentGroup.allMuteMode != .off
            || currentGroup.allMuteRepairRequired
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    SheetHeader(
                        symbol: "speaker.slash.fill",
                        title: "全员禁言",
                        subtitle: currentGroup.allMuteStatusText(),
                        showsCloseButton: true
                    )

                    VStack(spacing: 12) {
                        GroupMuteModeCard(
                            title: "一直禁言",
                            subtitle: "确认后立即生效，需管理员手动关闭",
                            symbol: "infinity",
                            isSelected: selectedMode == .always
                        ) {
                            selectedMode = .always
                            inlineMessage = nil
                        }
                        GroupMuteModeCard(
                            title: "固定时段",
                            subtitle: "按设置的开始与结束时间自动生效",
                            symbol: "calendar.badge.clock",
                            isSelected: selectedMode == .scheduled
                        ) {
                            selectedMode = .scheduled
                            inlineMessage = nil
                        }
                    }

                    if selectedMode == .scheduled {
                        VStack(spacing: 14) {
                            GroupMuteTimeRow(title: "开始时间", selection: $startAt)
                            Divider()
                            GroupMuteTimeRow(title: "结束时间", selection: $endAt, showsNextDay: endsOnNextDay)
                            HStack(spacing: 8) {
                                Image(systemName: "clock.badge.checkmark.fill")
                                Text("禁言时段：\(schedulePreview)")
                                Spacer()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IMColor.muted)
                        }
                        .padding(16)
                        .plainCard(radius: 24)
                    }

                    if currentGroup.allMuteRepairRequired {
                        Label(
                            "当前禁言数据需要管理员重新保存或关闭；修复前普通成员保持禁言。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IMColor.danger.opacity(0.08)))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("禁言期间，群主和管理员仍可正常发消息。", systemImage: "checkmark.shield.fill")
                        Label("普通成员的文字、表情、附件和语音发送都会被阻止，草稿会保留。", systemImage: "text.bubble.fill")
                        Label("固定时段采用服务器时间；结束时间不包含在禁言区间内。", systemImage: "clock.fill")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.warning.opacity(0.08)))

                    if let message = inlineMessage ?? state.groupMuteErrorMessage(for: currentGroup.id) {
                        Text(message)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IMColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    PrimaryButton(
                        title: isSubmitting
                            ? "正在保存…"
                            : (selectedMode == .always ? "立即开启" : "保存时段"),
                        systemImage: isSubmitting ? nil : "checkmark.shield.fill",
                        disabled: isSubmitting
                    ) {
                        if selectedMode == .always {
                            showAlwaysConfirmation = true
                        } else {
                            submit(mode: .scheduled)
                        }
                    }

                    if canCloseMute {
                        Button {
                            showCloseConfirmation = true
                        } label: {
                            Text("关闭禁言")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(IMColor.danger)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(IMColor.danger.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .accessibilityHint("关闭后普通成员立即恢复发送权限")
                    }
                }
                .padding(18)
            }
        }
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        }
        .alert("立即开启一直禁言？", isPresented: $showAlwaysConfirmation) {
            Button("取消", role: .cancel) {}
            Button("立即开启") {
                submit(mode: .always)
            }
        } message: {
            Text("确认后立即生效，普通成员将无法发言，群主和管理员仍可继续发言。")
        }
        .alert("关闭全员禁言？", isPresented: $showCloseConfirmation) {
            Button("取消", role: .cancel) {}
            Button("关闭禁言", role: .destructive) {
                submit(mode: .off)
            }
        } message: {
            Text("关闭后普通成员将立即恢复发送权限。")
        }
    }

    private func submit(mode: GroupMuteMode) {
        inlineMessage = nil
        let accepted = state.configureGroupMute(
            currentGroup.id,
            mode: mode,
            startAt: mode == .scheduled ? startAt : nil,
            endAt: mode == .scheduled ? normalizedEndAt : nil
        ) { succeeded in
            if succeeded {
                dismiss()
            } else {
                inlineMessage = state.groupMuteErrorMessage(for: currentGroup.id)
                    ?? state.toast
                    ?? "全员禁言设置失败，请重试"
            }
        }
        if !accepted {
            inlineMessage = state.toast ?? "全员禁言设置不合法"
        }
    }
}

private struct GroupMuteModeCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(isSelected ? .white : IMColor.brand)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isSelected ? IMColor.brand : IMColor.brand.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isSelected ? IMColor.brand : IMColor.muted.opacity(0.5))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.90))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? IMColor.brand.opacity(0.72) : IMColor.line, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct GroupMuteTimeRow: View {
    let title: String
    @Binding var selection: Date
    var showsNextDay = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)
            Spacer(minLength: 12)
            if showsNextDay {
                StatusPill(title: "次日", color: IMColor.warning)
            }
            DatePicker("", selection: $selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
    }
}

private struct GroupJoinApprovalSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(
                    symbol: "person.badge.shield.checkmark.fill",
                    title: "入群审批",
                    subtitle: currentGroup.inviteConfirmRequired ? "已开启，普通成员邀请需要审核。" : "未开启，符合条件的邀请可直接生效。",
                    showsCloseButton: true
                )
                VStack(spacing: 0) {
                    GroupToggleRow(
                        title: "开启入群审批",
                        subtitle: currentGroup.inviteConfirmRequired ? "普通成员邀请好友入群时，需要群主或管理员审批" : "关闭后，符合条件的邀请会直接生效",
                        isOn: Binding(
                            get: { currentGroup.inviteConfirmRequired },
                            set: { newValue in
                                if newValue != currentGroup.inviteConfirmRequired {
                                    state.toggleGroupInviteApproval(currentGroup.id, enabled: newValue)
                                }
                            }
                        )
                    )
                }
                .plainCard(radius: 24)
                VStack(alignment: .leading, spacing: 10) {
                    Label("仅群主和管理员可以修改入群审批开关。", systemImage: "checkmark.shield.fill")
                    Label("开启后，普通成员邀请好友时会给群主和管理员发送审批卡片。", systemImage: "tray.full.fill")
                    Label("审批通过后，被邀请人才会正式加入群聊。", systemImage: "person.crop.circle.badge.checkmark")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.warning.opacity(0.08)))
                PrimaryButton(title: "完成", systemImage: "checkmark.circle.fill") {
                    dismiss()
                }
            }
            .padding(18)
        }
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
            dismissForQueuedForcedAuthPromptIfNeeded()
        }
        .onChangeCompat(of: state.forcedAppPolicyAuthPrompt) { _, _ in
            dismissForQueuedForcedAuthPromptIfNeeded()
        }
    }

    private func dismissForQueuedForcedAuthPromptIfNeeded() {
        guard state.forcedAppPolicyAuthPrompt != nil else { return }
        dismiss()
    }
}

private struct GroupHistoryVisibilitySheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showEnableConfirm = false
    let group: GroupInfo

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var canManage: Bool {
        state.canManageGroup(currentGroup)
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(
                    symbol: "clock.arrow.circlepath",
                    title: "新成员可查看入群前消息",
                    subtitle: currentGroup.historyVisible ? "全部可见" : "仅入群后",
                    showsCloseButton: true
                )
                VStack(spacing: 0) {
                    GroupToggleRow(
                        title: "允许查看入群前消息",
                        subtitle: currentGroup.historyVisible ? "新加入成员可查看入群前消息" : "新加入成员仅可查看入群后的消息",
                        isEnabled: canManage,
                        isOn: Binding(
                            get: { currentGroup.historyVisible },
                            set: { newValue in
                                guard canManage else { return }
                                guard newValue != currentGroup.historyVisible else { return }
                                if newValue {
                                    showEnableConfirm = true
                                } else {
                                    state.toggleGroupHistoryVisibility(currentGroup.id, enabled: false)
                                }
                            }
                        )
                    )
                }
                .plainCard(radius: 24)
                VStack(alignment: .leading, spacing: 10) {
                    Label("仅影响之后加入或重新加入的成员。", systemImage: "person.crop.circle.badge.clock")
                    Label("修改后不会改变当前成员已经获得的历史消息权限。", systemImage: "lock.shield.fill")
                    if !canManage {
                        Label("仅群主和管理员可以修改此设置。", systemImage: "checkmark.shield.fill")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.warning.opacity(0.08)))
                PrimaryButton(title: "完成", systemImage: "checkmark.circle.fill") {
                    dismiss()
                }
            }
            .padding(18)
        }
        .alert("开启历史消息可见？", isPresented: $showEnableConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认开启") {
                state.toggleGroupHistoryVisibility(currentGroup.id, enabled: true)
            }
        } message: {
            Text("仅影响之后加入或重新加入的成员。修改后不会改变当前成员已经获得的历史消息权限。")
        }
        .onAppear {
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
        }
    }
}

private struct GroupMuteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let group: GroupInfo
    @State private var selectedMuted: Bool

    init(group: GroupInfo) {
        self.group = group
        _selectedMuted = State(initialValue: group.muted)
    }

    private var currentGroup: GroupInfo {
        state.group(id: group.id) ?? group
    }

    private var currentConversation: Conversation? {
        state.conversations.first { conversation in
            conversation.kind == .group
                && (conversation.id == currentGroup.id || conversation.title == currentGroup.name)
        }
    }

    private var currentMuted: Bool {
        GroupNotificationMuteProjection.isMuted(
            group: currentGroup,
            conversation: currentConversation
        )
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                SheetHeader(symbol: "bell.slash.fill", title: "群免打扰", subtitle: selectedMuted ? "该群未读使用灰色标识，不计入底部会话红点。" : "开启后保留未读，但不产生红色提醒。", showsCloseButton: true)
                GroupToggleRow(
                    title: "开启免打扰",
                    subtitle: selectedMuted ? "当前已开启免打扰" : "当前正常接收提醒",
                    isOn: Binding(
                        get: { selectedMuted },
                        set: { newValue in
                            if newValue != selectedMuted {
                                selectedMuted = newValue
                                state.toggleGroupMuted(currentGroup.id)
                            }
                        }
                    )
                )
                    .plainCard(radius: 24)
                PrimaryButton(title: "完成", systemImage: "checkmark") {
                    dismiss()
                }
            }
            .padding(18)
        }
        .onAppear {
            selectedMuted = currentMuted
        }
        .onChangeCompat(of: currentMuted) { _, newValue in
            selectedMuted = newValue
        }
    }
}

private struct GroupSheetActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = IMColor.brand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

private struct GroupToggleRow: View {
    let title: String
    let subtitle: String
    var isEnabled: Bool = true
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(IMColor.brand)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 12)
        .opacity(isEnabled ? 1 : 0.62)
    }
}

struct GroupHistoryVisibilityScreenshotHost: View {
    @EnvironmentObject private var state: AppState
    let scenario: GroupHistoryVisibilityScreenshotScenario

    private var group: GroupInfo {
        state.group(id: "group-history-boundary")
            ?? GroupInfo(
                id: "group-history-boundary",
                name: "历史边界验收群",
                notice: "用于 iOS 每群历史消息边界真实界面验收。",
                owner: "边界群主",
                ownerID: "im-history-owner",
                members: [],
                admins: [],
                muted: false,
                allMuted: false,
                allMuteStart: nil,
                allMuteEnd: nil,
                myRole: scenario == .ownerSettings ? "owner" : "member",
                memberCount: 3,
                historyVisible: scenario == .ownerSettings,
                historyVisibleFromSeq: scenario == .episodeWidened ? 1 : 421,
                historyLimited: scenario != .ownerSettings && scenario != .directUnaffected
            )
    }

    private var groupConversation: Conversation? {
        state.conversations.first { $0.id == "group-history-boundary" }
    }

    private var directConversation: Conversation? {
        state.conversations.first { $0.id == "direct-history-unaffected" }
    }

    var body: some View {
        switch scenario {
        case .ownerSettings, .ownerSettingsLimited:
            GroupHistoryVisibilitySheet(group: group)
                .environmentObject(state)
        case .memberReadonly:
            GroupHistoryVisibilitySheet(group: group)
                .environmentObject(state)
        case .restrictedGroup:
            NavigationStackCompat {
                ChatView(conversationID: group.id)
            }
        case .restrictedGroupFiles:
            GroupFilesSheet(group: group)
                .environmentObject(state)
        case .episodeWidened:
            NavigationStackCompat {
                ChatView(conversationID: group.id)
            }
        case .directUnaffected:
            NavigationStackCompat {
                ChatView(conversationID: directConversation?.id ?? "direct-history-unaffected")
            }
        }
    }
}

private struct GroupHistorySettingsScreenshotView: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    let roleText: String

    var body: some View {
        ZStack(alignment: .top) {
            GroupHistoryVisibilitySheet(group: group)
                .environmentObject(state)
            HStack(spacing: 8) {
                Label(roleText, systemImage: state.canManageGroup(group) ? "checkmark.shield.fill" : "lock.fill")
                Text(group.historyVisibilityStatusText)
            }
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(IMColor.ink.opacity(0.72)))
            .padding(.top, 54)
        }
    }
}

private struct GroupHistoryBoundaryEvidenceView: View {
    enum Mode {
        case restricted
        case episodeWidened
        case direct
    }

    let title: String
    let subtitle: String
    let group: GroupInfo
    let conversation: Conversation?
    let files: [FileItem]
    let mode: Mode

    private var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    private var visibleSeqText: String {
        let seqs = messages.map(\.channelSeq).filter { $0 > 0 }
        guard let first = seqs.first, let last = seqs.last else { return "无消息" }
        return first == last ? "seq \(first)" : "seq \(first)-\(last)"
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    statusGrid
                    if mode == .restricted {
                        limitedPrompt
                    }
                    if mode == .episodeWidened {
                        episodeEvidence
                    }
                    messageList
                    if mode != .direct {
                        derivedCacheEvidence
                    }
                    networkContract
                }
                .padding(.horizontal, 18)
                .padding(.top, 58)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(name: mode == .direct ? (conversation?.title ?? "单聊") : group.name, seed: group.historyLimited ? 0xF97316 : 0x5D6BFF, size: 48, badgeColor: group.historyLimited ? IMColor.warning : IMColor.success)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                }
                Spacer()
            }
            Text(mode == .direct ? "单聊路径不读取群历史边界，也不会裁剪 seq 1/2。" : "本页由真实 App 启动参数注入 fixture，展示同步合同进入本地渲染后的状态。")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .glassCard(radius: 28)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            evidenceStat(title: "边界", value: mode == .direct ? "不适用" : "\(group.historyVisibleFromSeq)", symbol: "number")
            evidenceStat(title: "状态", value: mode == .direct ? "完整" : (group.historyLimited ? "仅入群后" : "全部可见"), symbol: group.historyLimited ? "lock.fill" : "lock.open.fill")
            evidenceStat(title: "首屏消息", value: visibleSeqText, symbol: "bubble.left.and.bubble.right.fill")
            evidenceStat(title: "本地资料", value: mode == .restricted ? "0 条" : "\(files.count) 条", symbol: "folder.fill")
        }
    }

    private func evidenceStat(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(IMColor.brand)
                .frame(width: 32, height: 32)
                .background(Circle().fill(IMColor.brand.opacity(0.10)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IMColor.muted)
                Text(value)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .plainCard(radius: 18)
    }

    private var limitedPrompt: some View {
        Label("你只能查看本次入群后的消息", systemImage: "lock.shield.fill")
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(IMColor.warning)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(IMColor.warning.opacity(0.12)))
    }

    private var episodeEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("服务端回显 history_visible_from_seq = 1", systemImage: "arrow.triangle.2.circlepath")
            Label("421→1 视为新 membership episode：先清旧 snapshot，再重拉。", systemImage: "trash.slash.fill")
            Label("乱序旧请求通过 generation guard 丢弃。", systemImage: "clock.badge.exclamationmark.fill")
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(IMColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.success.opacity(0.10)))
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(mode == .direct ? "单聊消息窗口" : "群消息窗口")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Text("\(messages.count) 条")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.brand)
            }
            ForEach(messages) { message in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(message.channelSeq)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 28)
                        .background(Capsule().fill(IMColor.brand))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.senderName)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.ink)
                        Text(message.text)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IMColor.ink.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.72)))
            }
        }
        .padding(16)
        .plainCard(radius: 24)
    }

    private var derivedCacheEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(mode == .restricted ? "预览/未读：不显示边界前数据" : "预览/未读：随新窗口重新计算", systemImage: "text.bubble.fill")
            Label(mode == .restricted ? "置顶：边界前置顶已被裁剪" : "置顶：重拉后按新边界恢复", systemImage: "pin.fill")
            Label(mode == .restricted ? "资料：边界前文件不闪现" : "资料：只展示新 episode 可见文件", systemImage: "folder.fill")
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(IMColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(IMColor.brand.opacity(0.08)))
    }

    private var networkContract: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络合同")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IMColor.ink)
            Text(mode == .direct ? "direct conversation DTO 不读取群 history_limited；POST /api/im/sync 的 group 边界只对 group 生效。" : "POST /api/im/sync 顶层返回 items / has_more_before / has_more_after / history_visible_from_seq / history_limited。")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .plainCard(radius: 20)
    }
}

struct SettingsRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var badgeCount: Int = 0
    var tint: Color = IMColor.brand
    var titleColor: Color = IMColor.ink
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(tint.opacity(0.10)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IMColor.muted)
                }
            }
            Spacer()
            if let badgeText = UnreadBadgeFormatter.text(badgeCount) {
                Text(badgeText)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(IMColor.danger))
                    .accessibilityLabel("\(title)有\(badgeText)条未读")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IMColor.muted)
        }
        .contentShape(Rectangle())
    }
}

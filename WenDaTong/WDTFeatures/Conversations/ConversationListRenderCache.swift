import IM4Features
import IM4Stores
import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import UIKit

extension ConversationListView {
    // JHT_MOD_BEGIN CONVERSATION_LIST_RENDER_LOOP_PERF_20260912 - 修改开始：复用筛选判断，后续 render 可单次遍历构建列表
    private func conversationMatchesCurrentList(_ conversation: ConversationMessageSnapshot, keyword: String) -> Bool {
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

    // Keep the list order on the conversation summary as history loads.
    private func conversationSortScore(_ conversation: ConversationMessageSnapshot, messageTimestamp: TimeInterval?) -> Double {
        if conversation.sortTimestamp > 0 {
            return conversationListNormalizedTimestamp(conversation.sortTimestamp, now: listClockTick)
        }
        if let messageTimestamp {
            return conversationListNormalizedTimestamp(messageTimestamp, now: listClockTick)
        }
        if let displayTimestamp = conversationListDisplayTimestamp(conversation.time, now: listClockTick) {
            return displayTimestamp
        }
        return Double(conversationDisplaySortScore(conversation.time))
    }

    func conversationDisplayTitle(for conversation: ConversationMessageSnapshot) -> String {
        if conversation.kind == .direct,
           let participant = state.directConversationProfilePeer(for: conversation) {
            return state.remarkPreferredDisplayName(for: participant)
        }
        return conversation.title
    }

    // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
    // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_BEGIN
    func conversationListProjectionDate(_ date: Date = Date()) -> Date {
        #if DEBUG
        if let override = ConversationListProjectionDiagnostics.clock?(state.conversationStore.messageMemoryStore.bindingID) {
            return override
        }
        #endif
        return date
    }
    // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_END

    private var rowProjectionContext: ConversationRowProjectionContext {
        ConversationRowProjectionContext(
            viewer: state.currentUser, viewerIDs: state.currentUserIdentitySet(),
            tenant: state.remoteDataScopeKey(for: state.apiContext) + "|" + state.currentEnterprise.name, mentionTarget: mentionTarget,
            minute: Int(listClockTick.timeIntervalSince1970 / 60),
            showsGroupCount: state.shouldShowGroupMemberCount,
            showsProcessingNotices: state.shouldShowMessageProcessingNotices,
            certificationRevision: state.certificationPresentationRevision
        )
    }

    private func makeRowProjection() -> (ConversationMessageSnapshot) -> ConversationRenderItem {
        let contactLookup = DirectConversationCallPeerResolver.ContactLookup(contacts: state.contacts)
        let userLookup = state.makeConversationUserLookup()
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

        func directConversationProfilePeerForRender(_ conversation: ConversationMessageSnapshot) -> IMUser? {
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

        func directConversationCertificationUIDForRender(_ conversation: ConversationMessageSnapshot, resolvedPeer: IMUser?) -> String? {
            guard conversation.kind == .direct else { return nil }

            if let peer = resolvedPeer,
               let uid = state.userIdentityCandidates(for: peer).first(where: { !currentProfileIdentityIDs.contains($0) }) {
                return uid
            }

            if let uid = firstUniqueDirectPeerIDForRender(conversation.participants.map(\.id)) {
                return uid
            }

            if let uid = firstUniqueDirectPeerIDForRender(
                state.directChannelParts(state.remoteChannelID(for: conversation, lookup: userLookup)) + state.directChannelParts(conversation.id)
            ) {
                return uid
            }

            return conversation.messages.reversed().lazy
                .map(\.senderId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !currentProfileIdentityIDs.contains($0) }
        }
        // JHT_MOD_END CONVERSATION_LIST_DIRECT_IDENTITY_CACHE_PERF_20260912 - 修改结束
        let groupCounts = state.groups.reduce(into: [String: Int]()) { counts, group in
            if let count = state.visibleGroupMemberCount(group.memberCount) {
                counts[group.id] = count
            }
        }
        return { conversation in
            if let item = conversationRowProjectionCache.value(for: conversation) { return item }
            #if DEBUG
            ConversationListLayoutDiagnostics.rowProjections += 1
            #endif
            // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_PERF_BEGIN_ROW_PRESENTATION_BUILD - 修改开始：会话列表行展示数据提前缓存，减少滑动时逐行查全局状态
            let directPeer = conversation.kind == .direct
                ? directConversationProfilePeerForRender(conversation)
                : nil
            let displayTitle: String = {
                guard conversation.kind == .direct, let directPeer else {
                    return conversation.title
                }
                return state.remarkPreferredDisplayName(for: directPeer, contactLookup: contactLookup)
            }()
            let directCertificationUID = conversation.kind == .direct
                ? (directConversationCertificationUIDForRender(conversation, resolvedPeer: directPeer) ?? directPeer?.id ?? "")
                : ""
            let directCertificationPresentation = directCertificationUID.isEmpty
                ? nil
                : state.certificationPresentation(forExactUID: directCertificationUID)
            let rowPresentation: ConversationRowAvatarInput = {
                switch conversation.kind {
                case .direct:
                    return ConversationRowAvatarInput(
                        avatarURL: directPeer?.displayAvatarURL ?? "",
                        avatarVersion: directPeer?.avatarVersion ?? "",
                        avatarUpdatedAt: directPeer?.avatarUpdatedAt ?? "",
                        avatarImageCacheKey: "",
                        directCertificationUID: directCertificationUID,
                        directCertificationPresentation: directCertificationPresentation?.conversationFeatureInput
                    )
                case .group:
                    return ConversationRowAvatarInput(
                        avatarURL: conversation.avatarURL,
                        avatarVersion: conversation.avatarVersion,
                        avatarUpdatedAt: conversation.avatarUpdatedAt,
                        avatarImageCacheKey: state.groupAvatarCacheKey(for: conversation),
                        directCertificationUID: "",
                        directCertificationPresentation: nil
                    )
                case .system:
                    return ConversationRowAvatarInput(
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
            // A loaded message can refine the displayed time without moving the row.
            let messageTimestamp = conversationListMessageTimestamp(conversation)
            var summary = conversation
            summary.messages = []
            let item = ConversationRenderItem(
                conversation: summary,
                displayTitle: displayTitle,
                unreadMention: latestUnreadMention(in: conversation),
                sortScore: conversationSortScore(conversation, messageTimestamp: messageTimestamp),
                requiresClockSort: conversation.sortTimestamp <= 0 && messageTimestamp == nil
                    && conversation.time.trimmingCharacters(in: .whitespacesAndNewlines) == "刚刚",
                directCertificationPresentation: directCertificationPresentation,
                // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：预构建轻量行模型，滚动渲染不再持有完整消息数组
                rowModel: ConversationRowModel(
                    id: conversation.id,
                    kind: conversation.kind,
                    displayTitle: displayTitle,
                    groupMemberCount: conversation.kind == .group && state.shouldShowGroupMemberCount
                        ? state.visibleGroupMemberCount(conversation.memberCount)
                            ?? groupCounts[state.remoteChannelID(for: conversation, lookup: userLookup)]
                            ?? groupCounts[conversation.id]
                        : nil,
                    lastMessage: state.visibleConversationLastMessage(conversation),
                    time: messageTimestamp == 0 ? "" : conversation.time,
                    unread: conversation.unread,
                    isPinned: conversation.isPinned,
                    isMuted: conversation.isMuted,
                    accentHex: conversation.accentHex,
                    hasUnreadReaction: conversation.hasUnreadReaction,
                    unreadReactionCount: conversation.unreadReactionCount,
                    sortTimestamp: messageTimestamp ?? conversation.sortTimestamp,
                    rowPresentation: rowPresentation
                )
                // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
            )
            conversationRowProjectionCache.store(item, source: conversation)
            return item
        }
    }

    func invalidateConversationRowProjections() {
        conversationRowProjectionCache.invalidate()
        conversationListMemoryChanges.requireFull()
    }

    private func publishConversationSections(_ sections: ConversationRenderSections) {
        guard cachedConversationSections.ordered != sections.ordered else { return }
        installConversationSections(sections)
    }

    private func installConversationSections(_ sections: ConversationRenderSections) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cachedConversationSections = sections
            conversationRowsRevision &+= 1
        }
    }

    private func rebuildConversationProjection() {
        let store = state.conversationStore.messageMemoryStore
        let snapshots = state.conversationStore.conversationMessageSnapshots()
        observedHasConversations = !snapshots.isEmpty
        #if DEBUG
        ConversationListLayoutDiagnostics.sectionRebuilds += 1
        ConversationListProjectionDiagnostics.didProject?(store.bindingID, nil)
        #endif
        // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_BEGIN
        let representatives = conversationListMemoryChanges.representativeRows(in: snapshots)
        conversationRowProjectionCache.prepare(context: rowProjectionContext, activeIDs: Set(representatives.map(\.id)))
        if filter == "@我" {
            publishConversationSections(.empty)
        } else {
            let keyword = trimmedSearchQuery
            let project = makeRowProjection()
            let rows = representatives.lazy.filter { conversationMatchesCurrentList($0, keyword: keyword) }
                .map(project).sorted(by: ConversationRenderSections.precedes)
            publishConversationSections(ConversationRenderSections(ordered: rows))
        }
        // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112_END
        rebuildMentionCache(from: snapshots, includeRecords: filter == "@我")
        conversationListMemoryChanges.didProject(binding: store.bindingID, revision: store.revision)
    }

    private func rebuildMentionCache(from snapshots: [ConversationMessageSnapshot], includeRecords: Bool) {
        if includeRecords {
            cachedMentionRecords = renderMentionRecords(in: snapshots)
        }
        var counts: [String: Int] = [:]
        var total = 0
        for row in snapshots {
            let count = listUnreadMentionCount(in: row)
            counts[row.id, default: 0] += count
            total += count
        }
        conversationListMemoryChanges.replaceMentions(counts)
        cachedUnreadMentionCount = total
    }

    func receiveConversationMemoryCommit(_ commit: ConversationStore.MemoryCommit) {
        let store = state.conversationStore.messageMemoryStore
        guard commit.bindingID == store.bindingID else { return }
        if conversationListMemoryChanges.needsRebind(to: store) {
            conversationListMemoryChanges.reset(binding: store.bindingID)
            conversationRowProjectionCache.invalidate()
            publishConversationSections(.empty)
            cachedMentionRecords = []
            cachedUnreadMentionCount = 0
        }
        if conversationListMemoryChanges.receive(commit, activeBinding: store.bindingID) {
            scheduleConversationStoreChangeHandling()
        }
    }

    private func applyConversationMemoryChanges() {
        guard !isConversationListInteracting else {
            conversationRenderCacheDirtyWhileInteracting = true
            return
        }
        let store = state.conversationStore.messageMemoryStore
        if conversationListMemoryChanges.needsRebind(to: store) {
            rebuildConversationProjection()
            return
        }
        switch conversationListMemoryChanges.pending {
        case .none:
            return
        case .full:
            rebuildConversationProjection()
        case .rows(let ids):
            guard filter != "@我", conversationRowProjectionCache.matches(context: rowProjectionContext),
                  !cachedConversationSections.requiresClockSort else {
                rebuildConversationProjection()
                return
            }
            let keyword = trimmedSearchQuery
            let project = makeRowProjection()
            var next = cachedConversationSections
            var mentions: [String: Int] = [:]
            var rowsChanged = false
            for id in ids.sorted() {
                guard let row = conversationListMemoryChanges.row(id: id, in: store) else {
                    rebuildConversationProjection()
                    return
                }
                let matches = conversationMatchesCurrentList(row, keyword: keyword)
                let previous = next.itemsByID[id]
                guard matches == (previous != nil) else {
                    rebuildConversationProjection()
                    return
                }
                if matches {
                    let item = project(row)
                    if previous != item {
                        guard !item.requiresClockSort, next.replaceSamePosition(item) else {
                            rebuildConversationProjection()
                            return
                        }
                        rowsChanged = true
                    }
                }
                mentions[id] = listUnreadMentionCount(in: row)
            }
            #if DEBUG
            ConversationListProjectionDiagnostics.didProject?(store.bindingID, ids)
            #endif
            if rowsChanged { installConversationSections(next) }
            for (id, count) in mentions {
                let delta = conversationListMemoryChanges.updateMentions(id: id, count: count)
                if delta != 0 { cachedUnreadMentionCount += delta }
            }
            conversationListMemoryChanges.didProject(binding: store.bindingID, revision: store.revision)
        }
    }
    // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END

    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    func rebuildAnnouncementCache(from announcements: [InboxItem]? = nil) {
        let unread = (announcements ?? state.contactStore.announcements).filter { !$0.isRead }
        if cachedAnnouncementItems != unread { cachedAnnouncementItems = unread }
    }
    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END

    func rebuildConversationRenderCaches() {
        guard !isConversationListInteracting else {
            conversationRenderCacheDirtyWhileInteracting = true
            return
        }
        rebuildConversationProjection()
    }

    func scheduleConversationStoreChangeHandling() {
        // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：聊天页显示时延后会话列表 UI 缓存响应
        if selectedConversationRoute != nil {
            conversationStoreChangeCoalescer.cancelPending()
            markConversationRenderCacheDirtyWhileRouteActive(reason: "store_change")
            return
        }
        // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束
        guard let token = conversationStoreChangeCoalescer.begin() else { return }
        // Coalesce installed commits before collecting the affected rows.
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
        if isConversationListInteracting {
            conversationRenderCacheDirtyWhileInteracting = true
            return
        }
        if filter == "未读" || filter == "@我" {
            conversationCacheRebuildTask?.cancel()
            conversationCacheRebuildTask = nil
            applyConversationMemoryChanges()
        } else {
            scheduleConversationRenderCacheRebuild(memoryOnly: true)
        }
    }

    func scheduleConversationRenderCacheRebuild(now: Date = Date(), memoryOnly: Bool = false) {
        if !memoryOnly { conversationListMemoryChanges.requireFull() }
        guard !isConversationListInteracting else {
            conversationRenderCacheDirtyWhileInteracting = true
            return
        }
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
            listClockTick = conversationListProjectionDate(now) // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
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
                listClockTick = conversationListProjectionDate() // WDT_IOS1_CONVERSATION_LIST_DUPLICATE_ROWS_20261112
            }
            applyConversationMemoryChanges()
        }
    }

    // JHT_MOD_BEGIN CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改开始：集中标记聊天页期间被延后的列表 UI 缓存重建
    func markConversationRenderCacheDirtyWhileRouteActive(reason: String) {
        guard selectedConversationRoute != nil else { return }
        let shouldLog = !conversationRenderCacheDirtyWhileRouteActive
        conversationRenderCacheDirtyWhileRouteActive = true
        conversationCacheRebuildTask?.cancel()
        conversationCacheRebuildTask = nil
        #if DEBUG
        if shouldLog {
            DebugConsoleDiagnostics.trace("[JHT Perf] conversation_list_lag event=defer_rebuild_route_active reason=\(reason) source_count=\(state.conversationStore.conversations.count) cached_count=\(cachedConversationSections.ordered.count)")
        }
        #endif
    }
    // JHT_MOD_END CHAT_ROUTE_DEFER_CONVERSATION_LIST_REBUILD_PERF_20260912 - 修改结束

    func rebuildQueryDependentCaches() {
        rebuildConversationProjection()
    }

    func rebuildAllRenderCaches() {
        rebuildConversationRenderCaches()
        rebuildAnnouncementCache()
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

import IM4Features
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_BEGIN
extension ChatView {
    @ViewBuilder
    var unlockedBody: some View {
#if DEBUG
        let _ = ChatTimelineRenderDiagnostics.recordTimelineBody() // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110
#endif
        let projection = transcriptProjection
        let renderMessages = projection.timeline
        let renderPinnedMessages = projection.pinned
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_RENDER_ROW_SNAPSHOT - 修改开始：渲染行携带缓存版本，减少输入重绘中的时间线 item 重建
        let renderMessageRowsSnapshot = cachedRowsForRendering(messages: renderMessages)
        let renderMessageRows = renderMessageRowsSnapshot.rows
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_RENDER_ROW_SNAPSHOT - 修改结束

        let layout = unlockedLayout(
            renderMessages: renderMessages,
            renderPinnedMessages: renderPinnedMessages,
            renderMessageRows: renderMessageRows,
            renderMessageRowsSnapshot: renderMessageRowsSnapshot
        )
        let lifecycle = chatConversationLifecycle(layout)
        let media = chatMediaPresentation(lifecycle)
        let messages = chatMessagePresentation(media)
        let deletion = chatDeletionPresentation(messages)
        chatEntryLifecycle(deletion)
    }

    func unlockedLayout(
        renderMessages: [ChatMessage],
        renderPinnedMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot
    ) -> some View {
        ChatScreenLayout(allowsBackSwipe: !isBatchForwardSelectionActive,
            isComposerEditing: isComposerEditing, isHistorySearchFocused: false, // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
            content: { chatContent(renderMessages: renderMessages, renderPinnedMessages: renderPinnedMessages,
                renderMessageRows: renderMessageRows, renderMessageRowsSnapshot: renderMessageRowsSnapshot) },
            actionOverlay: { chatMessageActionOverlay }, senderOverlay: { chatSenderActionOverlay },
            header: { conversationHeader })
    }

    func chatContent(renderMessages: [ChatMessage], renderPinnedMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow], renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot) -> some View {
        ChatScreenColumn(top: { chatTopContext(renderPinnedMessages: renderPinnedMessages) },
            timeline: { chatTimelineContainer(renderMessages: renderMessages,
                renderMessageRows: renderMessageRows, renderMessageRowsSnapshot: renderMessageRowsSnapshot) },
            mute: { chatGroupMuteStatus }, composer: {
                // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
                VStack(spacing: 0) {
                    historySearchLocator
                    chatComposerArea
                }
                // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
            })
    }

    @ViewBuilder
    func chatTimelineContainer(
        renderMessages: [ChatMessage], renderMessageRows: [ChatMessageRenderRow],
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot
    ) -> some View {
        ChatReturnToBottomOverlay(showsControl: chatShouldShowReturnToBottom(
            didInitialScroll: didInitialScroll, isApplyingInitialScroll: isApplyingInitialScroll,
            messageCount: renderMessages.count, isAtBottom: isAtBottom, isSearchVisible: showSearch,
            isReadOnlySystemConversation: isReadOnlySystemConversation),
            pendingUnreadCount: boundedPendingUnreadCount,
            returnToBottom: {
                let plan = chatReturnToBottomActionPlan(bottomAnchorID: bottomAnchorID)
                suppressAutomaticBottomScroll(reason: "return_to_bottom")
                setScrollTarget(plan.targetID, source: plan.source, anchor: plan.anchor)
            }) {
                screenStores.files.observeUploadConfiguration(\.config.readReceiptsEnabled) { enabled in
                    ScrollViewReader { reader in
                        messageTimeline(reader: reader, renderMessages: renderMessages,
                            renderMessageRows: renderMessageRows, renderMessageRowsSnapshot: renderMessageRowsSnapshot)
                    }
                    .environment(\.chatReadReceiptsEnabled, enabled)
                }
            }
    }

    func chatConversationLifecycle<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showDetail, onDismiss: {
            openPendingProfileConversationIfNeeded()
            if openHistorySearchAfterGroupDetail { // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
                openHistorySearchAfterGroupDetail = false
                openHistorySearch()
            }
        }) {
            if conversation.kind == .group {
                requiredContactsRouting(contactsFeatureRouting).makeGroupDetail(
                    group: currentGroup,
                    onSearchHistory: {
                        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
                        openHistorySearchAfterGroupDetail = true
                        showDetail = false
                        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
                    },
                    onPinnedMessages: secondaryPinnedDetailAction
                )
                    .presentationDetentsCompat([.large])
            }
        }
        .fullScreenCover(isPresented: $presentation.showSearch, onDismiss: historySearchDidDismiss) { // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
            historySearchCover
        }
        .onAppear {
            // Same-scope reappearance need not reset timeline position, but must
            // never inherit an unfinished gesture from the previous appearance.
            finishMessageTranscriptDrag()
            screenActions.history.subscribeRealtimeConversation(conversationID)
            updateRealtimeAutoReadGate()
            applyInitialSearchJumpTargetIfNeeded()
            screenActions.forwarding.refreshBatchForwardContext(conversationID: conversationID)
        }
        // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_BEGIN
        // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_BEGIN
        .onReceive(screenStores.conversations.conversationUpdates) { conversations in // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            if isBatchForwardSelectionActive {
                screenActions.forwarding.refreshBatchForwardTargets(conversationID: conversationID, conversations: conversations)
            }
        }
        .onReceive(screenStores.conversations.conversationMessageUpdates(id: conversationID)) { source in
            if isBatchForwardSelectionActive {
                screenActions.forwarding.refreshBatchForwardSource(conversationID: conversationID, source: source)
            }
        }
        // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_END
        // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110_END
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            screenActions.history.loadGroupDetailForConversation(conversationID, force: true, includeSecondaryData: false)
        }
        .onChangeCompat(of: isTranscriptDragRecognized) { _, isRecognized in
            // GestureState resets on cancellation too, unlike onEnded.
            if !isRecognized { finishMessageTranscriptDrag() }
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            readVisibilityEpoch &+= 1
            isClearingUnreadReminder = false
            lastVisibleReadAckToken = ""
            scrollMetricsMeasurements.layoutCallbacks.cancel()
            if phase != .active {
                mediaScrollActivity.resetMotion()
                screenActions.history.updateRealtimeConversationAutoRead(conversationID, canAutoRead: false)
                _ = nextAutomaticBottomScrollGeneration()
                finishMessageTranscriptDrag()
            }
        }
        .onDisappear {
            mediaScrollActivity.resetMotion()
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_DISAPPEAR - 修改开始：记录返回后 ChatView 是否真正退出
            chatBackDisappearedAttemptID = chatBackDismissAttemptID
            chatBackStuckDiagnostic(
                "chat_disappear",
                force: chatBackDismissAttemptID > 0,
                extra: "attempt=\(chatBackDismissAttemptID) elapsed_since_back_ms=\(Self.chatBackDiagnosticElapsedMS(since: chatBackDismissAttemptStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_DISAPPEAR - 修改结束：记录返回后 ChatView 是否真正退出
            readVisibilityEpoch &+= 1
            // WDT_CHAT_READ_TRIGGER_20261021_BEGIN: obsolete callbacks cannot release these flags on reappearance.
            isClearingUnreadReminder = false
            lastVisibleReadAckToken = ""
            // WDT_CHAT_READ_TRIGGER_20261021_END
            _ = nextAutomaticBottomScrollGeneration()
            scrollMetricsMeasurements.removeAll()
            finishMessageTranscriptDrag()
            // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
            if !showSearch && pendingHistorySearchJump == nil {
                historySearchSession.close(historySearchContext)
                cancelHistorySearchJump()
            }
            // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_CANCEL_RENDER_REFRESH_TASK - 修改开始：离开聊天页取消延迟消息行刷新
            messageRenderCacheRefreshTask?.cancel()
            messageRenderCacheRefreshTask = nil
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_CANCEL_RENDER_REFRESH_TASK - 修改结束：离开聊天页取消延迟消息行刷新
            screenActions.forwarding.leaveBatchForwardSourceConversation(conversationID)
            screenActions.history.updateRealtimeConversationAutoRead(conversationID, canAutoRead: false)
            screenActions.history.leaveRealtimeConversation(conversationID)
        }
        .sheet(isPresented: $presentation.showGroupAnnouncementDetail) {
            GroupAnnouncementSheet(
                group: currentGroup,
                announcementID: openedGroupAnnouncementID,
                onClose: secondaryAnnouncementCloseAction
            )
                .presentationDetentsCompat([.large])
        }
    }

    // WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111_BEGIN
    var chatDeletionAlerts: ChatMessageDeletionAlerts {
        ChatMessageDeletionAlerts(
            adminDeleteCandidate: Binding(get: { adminDeleteCandidate }, set: { adminDeleteCandidate = $0 }),
            failedDeleteCandidate: Binding(get: { failedDeleteCandidate }, set: { failedDeleteCandidate = $0 }),
            actions: secondaryDeletionActions
        )
    }

    func chatDeletionPresentation<Content: View>(_ content: Content) -> some View {
        content.modifier(chatDeletionAlerts)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: actionMessage?.id)
    }
    // WDT_IOS1_CHAT_DELETION_CONFIRMATION_FEATURE_20261111_END

    func chatEntryLifecycle<Content: View>(_ content: Content) -> some View {
        content
        .onAppear {
            beginChatOpenPerfTrace(reason: "view_appear")
            beginNormalOpenScrollWindow(reason: "view_appear")
            screenActions.history.prepareConversationTailWindowForEntry(conversationID)
            markSystemConversationReadOnOpenIfNeeded()
            captureInitialUnreadSnapshotIfNeeded()
            let hasCachedMessages = !conversation.messages.isEmpty
            let needsUnreadWindowRefresh = needsInitialUnreadWindowRefresh
            let needsLatestWindowRefresh = needsInitialLatestWindowRefresh && !canReuseConfirmedBottomForCurrentWindow
            let entrySyncPolicy = chatInitialEntrySyncPolicy(
                hasCachedMessages: hasCachedMessages,
                needsUnreadWindowRefresh: needsUnreadWindowRefresh,
                needsLatestWindowRefresh: needsLatestWindowRefresh,
                canReuseConfirmedBottom: canReuseConfirmedBottomForCurrentWindow
            )
            screenActions.history.syncConversationMessagesIfNeeded(
                conversationID,
                force: entrySyncPolicy.forceRemoteHistory,
                silent: entrySyncPolicy.silent,
                showLoadingIndicator: entrySyncPolicy.showLoadingIndicator,
                trimToLatestWindow: true
            )
            if entrySyncPolicy.shouldWarmRefreshAfterInitialRender {
                screenActions.history.scheduleWarmConversationRefreshAfterInitialRender(conversationID)
            }
            screenActions.history.syncReadReceiptsIfNeeded(conversationID)
            if conversation.kind == .group {
                screenActions.history.loadGroupDetailForConversation(conversationID, force: true, includeSecondaryData: false)
                screenActions.history.refreshPinnedMessages(for: conversationID)
            }
        }
        .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
            // Retry a failed pre-persistence attempt even if the viewport stays
            // still. The same actual-visibility and foreground guards apply.
            markVisibleIncomingMessagesReadIfNeeded()
            screenActions.history.syncReadReceiptsIfNeeded(conversationID)
            if screenActions.history.shouldPollConversation(conversationID) {
                screenActions.history.syncConversationMessagesIfNeeded(conversationID, force: true, silent: true, showLoadingIndicator: false)
            }
        }
        // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_BEGIN
        .onReceive(screenStores.searchInvalidation.updates) { event in
            applyHistorySearchInvalidation(event) // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
        }
        .onReceive(screenStores.conversations.memoryCommits) { commit in
            guard commit.bindingID == screenStores.conversations.messageMemoryStore.bindingID,
                  let change = commit.messageChanges[conversationID] else { return }
            historySearchSession.observeLocalMessageWindow(change.current, previous: change.previous, context: historySearchContext)
        }
        // WDT_IOS1_REFACTOR_SEARCH_INVALIDATION_OBSERVATION_20261110_END
        .onReceive(screenStores.sessionIdentity.updates, perform: retireHistorySearchForAuthority) // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
        .onChangeCompat(of: conversationID) { _, _ in retireHistorySearch() }
        .onChangeCompat(of: conversation.unread) { _, _ in
            markSystemConversationReadOnOpenIfNeeded()
            markVisibleIncomingMessagesReadIfNeeded()
        }
        .onChangeCompat(of: conversation.messageCoveredThroughSeq) { _, _ in
            // Filling a sequence hole can make an already visible target safe
            // to acknowledge without changing the message or viewport token.
            markVisibleIncomingMessagesReadIfNeeded()
        }
        .navigationDestinationCompat(item: $linkedConversationRoute) { route in
            requiredChatRouting(chatFeatureRouting).makeChat(route.id)
        }
    }

}
// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_END

// WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_BEGIN
private struct ChatReadReceiptsEnabledKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var chatReadReceiptsEnabled: Bool? {
        get { self[ChatReadReceiptsEnabledKey.self] }
        set { self[ChatReadReceiptsEnabledKey.self] = newValue }
    }
}
// WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

// WDT_IOS1_REFACTOR_CHAT_LAYOUT_SPLIT_20261110_BEGIN
extension ChatView {
    // WDT_IOS1_CHAT_TOP_CONTEXT_FEATURE_20261111_BEGIN
    func chatTopContext(renderPinnedMessages: [ChatMessage]) -> some View {
        chatTopContextContent(
            hasPinnedMessages: !renderPinnedMessages.isEmpty,
            // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110
            announcement: { observedGroupAnnouncementBanner },
            pinned: { pinnedContext(messages: renderPinnedMessages) },
            search: { EmptyView() } // WDT_IOS1_CHAT_SEARCH_PAGE_20261113
        )
    }
    // WDT_IOS1_CHAT_TOP_CONTEXT_FEATURE_20261111_END



    var chatMessageActionOverlay: some View { assembledMessageActionOverlay }
    var chatSenderActionOverlay: some View { assembledSenderActionOverlay }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

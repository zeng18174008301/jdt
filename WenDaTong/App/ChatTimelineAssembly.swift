import IM4Features
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
import SwiftUI
import UIKit

extension ChatView {
    @ViewBuilder
    func messageTimeline(
        reader: ScrollViewProxy,
        renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_PARAM - 修改开始：传入消息行缓存快照
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_PARAM - 修改结束
    ) -> some View {
        // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
        let store = screenStores.contacts.groupSelfProfiles
        let profileKey = conversation.kind == .group ? screenActions.people.groupMemberProfileCacheKey(groupID: currentGroup.id) : nil
        PublisherSnapshotView(
            initialValue: store.snapshot(for: profileKey).member,
            updates: store.updates(for: profileKey, \.member)
        ) { member in
            observedMessageTimeline(
                reader: reader,
                renderMessages: renderMessages,
                renderMessageRows: renderMessageRows,
                renderMessageRowsSnapshot: renderMessageRowsSnapshot,
                groupSelfMember: member
            )
        }
        // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END
    }

    // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
    private func observedMessageTimeline(
        reader: ScrollViewProxy,
        renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot,
        groupSelfMember: IMUser?
    ) -> some View {
        // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END
        messageScrollView(
            reader: reader,
            renderMessages: renderMessages,
            renderMessageRows: renderMessageRows,
            // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_FORWARD - 修改开始：向消息滚动视图传递行缓存快照
            renderMessageRowsSnapshot: renderMessageRowsSnapshot
            // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_TIMELINE_SIGNATURE_FORWARD - 修改结束
        )
            .contentShape(Rectangle())
            .simultaneousGesture(messageTranscriptTapGesture)
            .simultaneousGesture(messageTranscriptDragGesture)
            .onAppear {
                beginChatOpenPerfTrace(reason: "scroll_appear")
                previousMessageCount = conversation.messages.count
                refreshMessageRowCache(for: renderMessages)
                logChatFirstFrameIfNeeded(stage: "message_scroll")
                logChatHistoryReadyIfNeeded(reason: "scroll_appear")
                logChatSideDataReadyIfNeeded(reason: "scroll_appear")
                configureInitialPosition(reader)
                schedulePendingScrollTargetConsumption(reader)
            }
            .onChangeCompat(of: conversationID) { _, _ in
                beginChatOpenPerfTrace(reason: "conversation_change", force: true)
                beginNormalOpenScrollWindow(reason: "conversation_change")
                previousMessageCount = conversation.messages.count
                resetScrollPositionState(force: true)
                refreshMessageRowCache()
                configureInitialPosition(reader)
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_MESSAGE_CHANGE_COALESCE - 修改开始：避免监听整个 messages 数组导致历史多时比较卡顿
            // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
            .onReceive(screenStores.conversations.conversationMemoryCommits(id: conversationID)) { commit in
                guard let change = commit.messageChanges[conversationID],
                      let metadata = commit.current.conversations.first(where: { $0.id == conversationID }),
                      !chatMessagesShareStorage(change.previous, change.current) else { return }
                let updated = ConversationMessageSnapshot(conversation: metadata, messages: change.current)
                captureBottomBeforeMessageGrowth(updated, previousMessages: change.previous)
                refreshHistoryAnchorBeforeMessageGrowth(updated, previousMessageCount: change.previous.count)
                let publishedMessages = transcriptProjectionCache.projection(
                    for: updated.messages, showsProcessingNotices: screenActions.authority.processingNotices()
                ).timeline
                commit.realtimeSignposts[conversationID]?.forEach { $0.timelineObserved(revision: commit.current.revision, projected: publishedMessages, sceneActive: scenePhase == .active) } // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110
                if !chatMessagesShareStorage(cachedMessageRowsSource, publishedMessages),
                   chatNeedsImmediateRemovalRefresh(cachedMessages: cachedMessageRowsSource, messages: publishedMessages) {
                    refreshMessageRowCache(for: publishedMessages) // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110
                }
                scheduleMessageRenderCacheRefreshAfterStoreChange(reader)
            }
            // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_MESSAGE_CHANGE_COALESCE - 修改结束：避免监听整个 messages 数组导致历史多时比较卡顿
            .onChangeCompat(of: conversation.messages.count) { _, newCount in
                let oldCount = previousMessageCount
                previousMessageCount = newCount
                logChatHistoryReadyIfNeeded(reason: "message_count_changed")
                if scrollToBottomAfterOwnSendIfNeeded(reader, oldCount: oldCount, newCount: newCount) {
                    return
                }
                let didScheduleInitialPosition = configureInitialPosition(reader)
                if !didScheduleInitialPosition {
                    let didPreserveHistoryAnchor = preserveHistoryAnchorAfterMessageChangeIfNeeded(reader, oldCount: oldCount, newCount: newCount)
                    if !didPreserveHistoryAnchor {
                        followBottomAfterMessageChangeIfNeeded(reader, oldCount: oldCount, newCount: newCount)
                    }
                    autofillOlderHistoryIfUnderfilled()
                }
            }
            .onChangeCompat(of: latestLoadedMessageSeq) { _, _ in
                handleLatestWindowProgress(reader, reason: "latest_seq_changed")
            }
            .onChangeCompat(of: conversation.lastMsgSeq) { _, _ in
                handleLatestWindowProgress(reader, reason: "last_msg_seq_changed")
            }
            .onChangeCompat(of: isLoadingConversationHistory) { _, isLoading in
                guard !isLoading else { return }
                if !configureInitialPosition(reader) {
                    if didInitialScroll,
                       isAtBottom,
                       !isUserBrowsingHistory,
                       pendingUnreadCount == 0,
                       !conversation.messages.isEmpty {
                        scheduleLatestBottomConfirmation(reader, reason: "history_loading_finished_realign")
                    }
                    handleLatestWindowProgress(reader, reason: "history_loading_finished")
                    autofillOlderHistoryIfUnderfilled()
                }
            }
            .onChangeCompat(of: latestReadAcknowledgementToken) { _, _ in
                markVisibleIncomingMessagesReadIfNeeded()
            }
            .onChangeCompat(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                schedulePendingScrollTargetConsumption(reader, expectedTargetID: targetID)
            }
            // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
            .onChangeCompat(of: screenStores.files.currentUploadConfig().readReceiptsEnabled) { _, _ in refreshMessageRowCache() }
            .onChangeCompat(of: showsChatGroupMemberCount) { _, _ in refreshMessageRowCache() }
            // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END
            .onChangeCompat(of: conversation.participants) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
                logChatSideDataReadyIfNeeded(reason: "participants_changed")
            }
            .onChangeCompat(of: screenStores.contacts.contacts) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
            }
            .onChangeCompat(of: screenStores.contacts.remarks) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
            }
            .onChangeCompat(of: chatCurrentUser) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
            }
            .onChangeCompat(of: currentGroup.members) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
                logChatSideDataReadyIfNeeded(reason: "group_members_changed")
            }
            .onChangeCompat(of: currentGroup.admins) { _, _ in
                refreshMessageRowCache(allowsPrependReuse: false)
                logChatSideDataReadyIfNeeded(reason: "group_admins_changed")
            }
            .onChangeCompat(of: groupSelfMember) { _, _ in // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
                guard conversation.kind == .group else { return }
                refreshMessageRowCache(allowsPrependReuse: false)
            }
    }

    private func messageScrollView(
        reader: ScrollViewProxy, renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow], renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot
    ) -> some View {
        // Bind the observation to the rows participating in this layout, not a
        // newer conversation snapshot arriving before SwiftUI displays it.
        // WDT_CHAT_UNREAD_BADGE_20261021: do not require an older incoming row to remain onscreen below our replies.
        let readTarget = chatReadAcknowledgementTarget(in: renderMessageRows.lazy.map(\.message))
        let readLayout = ChatScrollReadLayout(
            token: readTarget.map { "\(conversationID):\($0.channelSeq)" } ?? "",
            sequence: readTarget?.channelSeq ?? 0,
            epoch: readVisibilityEpoch
        )
        let usesNativeGeometry = usesNativeChatScrollGeometry
        return ChatTranscriptScrollSurface(readLayout: readLayout, usesNativeGeometry: usesNativeGeometry,
            coordinateSpaceName: chatScrollCoordinateSpaceName, hidesGIFPlayback: previewImageAttachment != nil,
            mediaScrollActivity: mediaScrollActivity,
            metricsChanged: { receiveChatScrollMetrics($0, reader: reader) },
            incomingRowChanged: { row in
            // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_INCOMING_ROW_CALLBACK - 修改开始：最新入站消息几何无变化时跳过处理
            if !chatIncomingRowGeometryApproximatelyEqual(scrollMetricsMeasurements.incomingRow, row) {
                scrollMetricsMeasurements.incomingRow = row
                let metrics = scrollMetricsMeasurements.metrics
                // The rendered tail can change without changing scroll
                // geometry. Use its measured row to refresh the read identity.
                if usesNativeGeometry, metrics.isValid, !row.token.isEmpty,
                   row.token == readLayout.token, row.epoch == readLayout.epoch {
                    receiveChatScrollMetrics(readLayout.metrics(
                        viewportHeight: metrics.viewportHeight,
                        contentMinY: metrics.contentMinY,
                        contentMaxY: metrics.contentMaxY
                    ), reader: reader)
                }
                if metrics.isValid, metrics.bottomDistance <= 1 {
                    scheduleTranscriptLayoutUpdate(reader)
                }
            }
            // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_INCOMING_ROW_CALLBACK - 修改结束
            }, messageTopsChanged: { values in
            // JHT_MOD_BEGIN CHAT_PAGE_SCROLL_LAG_FIX_TOP_ANCHOR_CALLBACK - 修改开始：历史锚点测量无变化时不触发滚动处理
            if messageTopMeasurements.replace(
                with: values,
                isEnabled: shouldMeasureMessageTopAnchors
            ) {
                // Never load history or publish view state from a layout callback.
                scheduleTranscriptLayoutUpdate(reader)
            }
            // JHT_MOD_END CHAT_PAGE_SCROLL_LAG_FIX_TOP_ANCHOR_CALLBACK - 修改结束
            }, content: {
                messageListContent(renderMessages: renderMessages, renderMessageRows: renderMessageRows,
                    renderMessageRowsSnapshot: renderMessageRowsSnapshot, readTargetID: readTarget?.id)
            }, historyStatus: { messageHistoryStatusOverlay })
    }

    private var usesNativeChatScrollGeometry: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private func receiveChatScrollMetrics(_ metrics: ChatScrollMetricsSnapshot, reader: ScrollViewProxy) {
        guard metrics.isValid else { return }
        if abs(metrics.contentMinY - scrollMetricsMeasurements.metrics.contentMinY) >= 1 {
            mediaScrollActivity.recordOffsetChange()
        }
        guard scrollMetricsMeasurements.replace(with: metrics) else { return }
        let visibility = chatScrollVisibility(metrics: metrics)
        let shouldCheckHistory = !isLoadingConversationHistory && chatCanLoadOlderFromScrollMetrics(
            didUserInteractWithMessageScroll: didUserInteractWithMessageScroll,
            isUserBrowsingHistory: isUserBrowsingHistory,
            visibility: visibility
        )
        if chatNeedsTranscriptLayoutUpdate(from: scrollMetricsMeasurements.lastHandledMetrics, to: metrics)
            || shouldCheckHistory {
            scheduleTranscriptLayoutUpdate(reader)
        }
    }

    @ViewBuilder
    private var messageHistoryStatusOverlay: some View {
        if shouldShowConversationHistoryLoadingPill {
            ChatHistoryStatusPill(text: "正在同步聊天记录", isLoading: true)
                .allowsHitTesting(false)
        } else if let conversationHistoryMessage {
            ChatHistoryStatusPill(text: conversationHistoryMessage, isLoading: false)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func messageListContent(
        renderMessages: [ChatMessage],
        renderMessageRows: [ChatMessageRenderRow],
        // JHT_MOD_BEGIN CHAT_PAGE_INPUT_LAG_FIX_LIST_SIGNATURE_PARAM - 修改开始：传入消息行缓存快照生成时间线 item
        renderMessageRowsSnapshot: ChatMessageRenderRowsSnapshot,
        // JHT_MOD_END CHAT_PAGE_INPUT_LAG_FIX_LIST_SIGNATURE_PARAM - 修改结束
        readTargetID: String?
    ) -> some View {
        ChatTranscriptList(items: messageTimelineItems(renderMessageRows, snapshot: renderMessageRowsSnapshot), empty: {
        if shouldShowDirectEmptyHistoryState {
            ChatEmptyHistoryLayout {
            DirectChatEmptyHistoryView(
                title: directEmptyHistoryTitle,
                subtitle: directEmptyHistorySubtitle,
                retryTitle: canRetryDirectHistorySync ? "重新同步" : nil,
                retry: {
                    screenActions.history.syncConversationMessagesIfNeeded(
                        conversationID,
                        force: true,
                        silent: false,
                        showLoadingIndicator: true,
                        trimToLatestWindow: true
                    )
                }
            )
            }
        }
        }, itemContent: { item in
            messageTimelineItemView(item, messageCount: renderMessages.count, readTargetID: readTargetID)
        }, bottom: { messageListBottomAnchor })
    }

    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
    private func messageTimelineItems(_ rows: [ChatMessageRenderRow], snapshot: ChatMessageRenderRowsSnapshot) -> [ChatMessageTimelineItem] {
        timelineViewModel.items(
            snapshot: snapshot, // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110: keep read geometry and item rows on one immutable snapshot.
            unreadID: unreadDividerVisible ? firstUnreadMessageID : nil,
            unreadCount: unreadDividerVisible ? firstUnreadAnchorCount : 0,
            historyAnchorID: historyAnchorID(for:), unreadMarkerID: firstUnreadMarkerID
        )
    }
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END

    @ViewBuilder
    private func messageTimelineItemView(_ item: ChatMessageTimelineItem, messageCount: Int, readTargetID: String?) -> some View {
        ChatTimelineItemLayout(item: item, row: {
            messageRowView(item.row, messageCount: messageCount, readTargetID: readTargetID)
        }, anchor: {
            ChatMessageHistoryAnchor(messageID: item.row.message.id,
                coordinateSpaceName: chatScrollCoordinateSpaceName, measuresTop: shouldMeasureMessageTopAnchors)
        })
    }

    @ViewBuilder
    private func messageRowView(_ row: ChatMessageRenderRow, messageCount: Int, readTargetID: String?) -> some View {
        let isFocused = focusedTimelineMessageID == row.message.id
        let batchDisabledReason = isBatchForwardSelectionActive
            ? batchForwardDisabledReason(for: row.message)
            : nil
        let batchSelected = isBatchForwardSelectionActive && batchForwardSelectedSourceIDs.contains(row.message.id) // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110

        observeSecondaryMessageEntry(row.message) { actions in
        ChatTimelineRowDecoration(message: row.message, conversationID: conversationID,
            coordinateSpaceName: chatScrollCoordinateSpaceName, visibilityEpoch: readVisibilityEpoch,
            readTargetID: readTargetID, isFocused: isFocused, isBatchSelectionActive: isBatchForwardSelectionActive,
            batchSelected: batchSelected, batchDisabledReason: batchDisabledReason,
            toggleSelection: actions.toggleSelection) {
                ChatTimelineRow(
                    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110
                    row: row,
                    conversationID: conversationID,
                    isGroupConversation: conversation.kind == .group,
                    isBatchSelected: batchSelected,
                    onSelectionTap: isBatchForwardSelectionActive ? {
                        actions.toggleSelection()
                    } : nil
                ) {
                    actions.longPress()
                } onReadTap: {
                    actions.read()
                } onSenderTap: { user in
                    guard !isBatchForwardSelectionActive else { return }
                    guard !isReadOnlySystemConversation else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        selectedSenderActionUser = user
                    }
                } onContactCardTap: { user in
                    guard !isBatchForwardSelectionActive else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedUserProfile = user
                } onMentionTap: { user in
                    guard !isBatchForwardSelectionActive else { return }
                    guard !isReadOnlySystemConversation else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedUserProfile = user
                } onAttachmentTap: { message in
                    actions.attachment(message)
                }
                // WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
                // Value equality is applied after App observation and presentation assembly.
                // WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END
        }
        }
    }

    private var messageListBottomAnchor: some View {
        ChatTimelineBottomAnchor(height: messageListBottomAnchorHeight, anchorID: bottomAnchorID)
    }

    private var messageTranscriptTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                dismissChatKeyboardFromTranscript(trigger: .tap)
                dismissExpressionPanelFromTranscriptTap()
            }
    }

    private var messageTranscriptDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isTranscriptDragRecognized) { _, isRecognized, _ in
                // Only the boundary changes this value; do not publish each frame.
                if !isRecognized { isRecognized = true }
            }
            .onChanged { value in
                mediaScrollActivity.recordMotion()
                // Same-direction frames update only non-publishing bookkeeping.
                guard let transition = transcriptScrollControl.updateDrag(
                    translation: value.translation,
                    now: Date(),
                    suppressionInterval: automaticBottomScrollSuppressionInterval
                ) else { return }
                if transition.isStart {
                    oldestHistoryLoadAnchorID = nil
                    oldestHistoryLoadAnchorMinY = nil
                    didUserInteractWithMessageScroll = true
                    // WDT_CHAT_KEYBOARD_INSET_20261021: also handles short/underfilled transcripts on every supported iOS.
                    dismissChatKeyboardFromTranscript(trigger: .verticalScroll)
                    _ = evaluateScrollRequest(source: .userGesture, targetID: nil, anchor: nil, userInitiated: true)
                }
                didTriggerOlderHistoryLoadForScrollIntent = false
                newestHistoryLoadAnchorSeq = 0
                switch transition.direction {
                case .history:
                    isUserBrowsingHistory = true
                    isAtBottom = false
                    logInitialAnchorDecision("suppress_auto_bottom_user_history_drag", targetID: bottomAnchorID, unreadCount: rawInitialUnreadCount())
                case .latest:
                    isUserBrowsingHistory = false
                    if didInitialScroll {
                        didScrollTowardUnreadMessages = true
                    }
                }
                updateRealtimeAutoReadGate()
                markUnreadReminderReadIfUserScrolledTowardUnread()
            }
            .onEnded { _ in
                // Finish even if the last sample becomes horizontal, and use
                // actual final direction rather than translation from origin.
                finishMessageTranscriptDrag()
            }
    }

    func finishMessageTranscriptDrag() {
        if transcriptScrollControl.finishDrag(
            now: Date(),
            suppressionInterval: automaticBottomScrollSuppressionInterval
        ) == .latest {
            didTriggerOlderHistoryLoadForScrollIntent = false
        }
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_MESSAGE_ROW_RESOLVER - 修改开始：复用消息行解析器，支持旧消息增量构建
    func messageSenderResolver() -> MessageSenderResolver {
        MessageSenderResolver(
            currentUser: chatCurrentUser,
            enterpriseName: chatEnterpriseName, // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
            conversation: conversation,
            contacts: screenStores.contacts.contacts,
            group: conversation.kind == .group ? currentGroup : nil,
            exactGroupSelf: conversation.kind == .group
                ? screenActions.people.myGroupMemberProjection(groupID: currentGroup.id)
                : nil,
            contactRemarks: screenStores.contacts.remarks
        )
    }

    func messageRow(
        for messages: [ChatMessage],
        at index: Int,
        resolver: MessageSenderResolver
    ) -> ChatMessageRenderRow {
#if DEBUG
        ChatTimelineRenderDiagnostics.recordRowResolution() // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110
#endif
        let message = messages[index]
        let previousMessage = index > 0 ? messages[index - 1] : nil
        let senderUser = resolver.senderUser(for: message)
        return ChatMessageRenderRow(
            index: index,
            message: message,
            showsSenderHeader: chatShouldShowSenderHeader(for: message, at: index, in: messages),
            senderUser: senderUser,
            displaySenderName: resolver.displaySenderName(for: message, resolvedUser: senderUser),
            timeSeparatorText: timeSeparatorText(before: message, previous: previousMessage)
        )
    }

    func messageRows(for messages: [ChatMessage]) -> [ChatMessageRenderRow] {
        let resolver = messageSenderResolver()
        return messages.indices.map { index in
            messageRow(for: messages, at: index, resolver: resolver)
        }
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_MESSAGE_ROW_RESOLVER - 修改结束：复用消息行解析器，支持旧消息增量构建

    func timeSeparatorText(before message: ChatMessage, previous: ChatMessage?) -> String? {
        chatTimeSeparatorText(before: message, previous: previous, threshold: Self.messageTimeSeparatorThreshold)
    }

}

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END

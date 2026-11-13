import IM4Features
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_BEGIN
import Combine // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110 // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import SwiftUI
import IM4DesignSystem // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit
import QuickLook

#if DEBUG
let chatBackDiagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("-WDTChatBackDiagnostics")
#endif

@MainActor
func dismissActiveChatKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}



struct ChatLinkedConversationRoute: Identifiable, Hashable {
    let id: String
}



struct ChatView: View {
    @StateObject var presentation = ChatScreenPresentationState()
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    @State var composerState = ComposerState()
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    @StateObject var messagePresentation = ChatMessagePresentationState()
    // WDT_IOS1_CHAT_STATE_20261023_END
    @State private var observedCurrentUser: IMUser? // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
    var chatCurrentUser: IMUser { observedCurrentUser ?? screenStores.currentUser.user } // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
    @Environment(\.chatFeatureRouting) var chatFeatureRouting
    @Environment(\.contactsFeatureRouting) var contactsFeatureRouting
    @Environment(\.chatScreenStores) private var scopedScreenStores

    var screenStores: ChatScreenStores {
        guard let scopedScreenStores else {
            preconditionFailure("ChatView must be mounted with appStateEnvironment.")
        }
        return scopedScreenStores
    }

    @Environment(\.chatScreenActions) private var scopedScreenActions

    var screenActions: ChatScreenActions {
        guard let scopedScreenActions else {
            preconditionFailure("ChatView must be mounted with appStateEnvironment.")
        }
        return scopedScreenActions.actions
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @State private var observedComposerScope: [String?]?
    @State var readVisibilityEpoch = 0
    let conversationID: String
    var initialSearchJumpTarget: RemoteTenantSearchJumpTarget? = nil
    static let messageTimeSeparatorThreshold: TimeInterval = 5 * 60
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var input: String {
        get { composerState.draft.input }
        nonmutating set { composerState.draft.replaceInputMovingCaretToEnd(newValue) } // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_CHAT_KEYBOARD_INSET_20261021: UIKit editor lifetime controls keyboard avoidance, not draft contents.
    var isComposerEditing: Bool { presentation.isComposerEditing }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var showTools: Bool {
        get { composerState.draft.showTools }
        nonmutating set { composerState.draft.showTools = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var showEmoji: Bool {
        get { composerState.draft.showEmoji }
        nonmutating set { composerState.draft.showEmoji = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var actionMessage: ChatMessage? {
        get { messagePresentation.actionMessage }
        nonmutating set { messagePresentation.actionMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var reactionMessage: ChatMessage? {
        get { messagePresentation.reactionMessage }
        nonmutating set { messagePresentation.reactionMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var receiptMessage: ChatMessage? {
        get { messagePresentation.receiptMessage }
        nonmutating set { messagePresentation.receiptMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var editMessage: ChatMessage? {
        get { messagePresentation.editMessage }
        nonmutating set { messagePresentation.editMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var reportMessage: ChatMessage? {
        get { messagePresentation.reportMessage }
        nonmutating set { messagePresentation.reportMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    var showBatchForwardTargets: Bool { get { presentation.showBatchForwardTargets } nonmutating set { presentation.showBatchForwardTargets = newValue } }
    @State private var observedEnterpriseName: String? // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
    @State private var observedGroupCountVisibility: Bool? // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
    @State private var observedTenantChatPolicy: TenantInteractionPresentationStore.ChatPolicy? // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
    @State private var observedBatchForwardSelection: BatchForwardPresentationStore.SourceSelection? // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var adminDeleteCandidate: ChatMessage? {
        get { messagePresentation.adminDeleteCandidate }
        nonmutating set { messagePresentation.adminDeleteCandidate = newValue }
    }

    var failedDeleteCandidate: ChatMessage? {
        get { messagePresentation.failedDeleteCandidate }
        nonmutating set { messagePresentation.failedDeleteCandidate = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var replyQuote: String? {
        get { composerState.draft.replyQuote }
        nonmutating set { composerState.draft.replyQuote = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var replyContext: MessageReplyContext? {
        get { composerState.draft.replyContext }
        nonmutating set { composerState.draft.replyContext = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    @State var showDetail = false
    var showGroupAnnouncement: Bool { get { presentation.showGroupAnnouncement } nonmutating set { presentation.showGroupAnnouncement = newValue } }
    var showGroupAnnouncementDetail: Bool { get { presentation.showGroupAnnouncementDetail } nonmutating set { presentation.showGroupAnnouncementDetail = newValue } }
    var openedGroupAnnouncementID: String? { get { presentation.openedGroupAnnouncementID } nonmutating set { presentation.openedGroupAnnouncementID = newValue } }
    @State var isOpeningGroupAnnouncementDetail = false
    @State var isMarkingGroupAnnouncementRead = false
    var showPinnedMessages: Bool { get { presentation.showPinnedMessages } nonmutating set { presentation.showPinnedMessages = newValue } }
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var pendingPinnedJumpMessage: ChatMessage? {
        get { messagePresentation.pendingPinnedJumpMessage }
        nonmutating set { messagePresentation.pendingPinnedJumpMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    var pinnedCarouselIndex: Int { get { presentation.pinnedCarouselIndex } nonmutating set { presentation.pinnedCarouselIndex = newValue } }
    var scrollTargetID: String? { get { presentation.scrollTargetID } nonmutating set { presentation.scrollTargetID = newValue } }
    var focusedTimelineMessageID: String? { get { presentation.focusedTimelineMessageID } nonmutating set { presentation.focusedTimelineMessageID = newValue } }
    var focusedTimelineMessageGeneration: Int { get { presentation.focusedTimelineMessageGeneration } nonmutating set { presentation.focusedTimelineMessageGeneration = newValue } }
    var pendingUnreadCount: Int { get { presentation.pendingUnreadCount } nonmutating set { presentation.pendingUnreadCount = newValue } }
    var previousMessageCount: Int { get { presentation.previousMessageCount } nonmutating set { presentation.previousMessageCount = newValue } }
    var didInitialScroll: Bool { get { presentation.didInitialScroll } nonmutating set { presentation.didInitialScroll = newValue } }
    @State var capturedUnreadCount = 0
    var didAutoScrollToUnreadAnchor: Bool { get { presentation.didAutoScrollToUnreadAnchor } nonmutating set { presentation.didAutoScrollToUnreadAnchor = newValue } }
    @State var initialUnreadSnapshot: Int?
    @State var initialUnreadAnchorLoadAttempts = 0
    var unreadDividerVisible: Bool { get { presentation.unreadDividerVisible } nonmutating set { presentation.unreadDividerVisible = newValue } }
    var didInitialLatestWindowCatchupScroll: Bool { get { presentation.didInitialLatestWindowCatchupScroll } nonmutating set { presentation.didInitialLatestWindowCatchupScroll = newValue } }
    var didScheduleInitialProvisionalBottom: Bool { get { presentation.didScheduleInitialProvisionalBottom } nonmutating set { presentation.didScheduleInitialProvisionalBottom = newValue } }
    var didResolveReadStatusAnchorAfterSideData: Bool { get { presentation.didResolveReadStatusAnchorAfterSideData } nonmutating set { presentation.didResolveReadStatusAnchorAfterSideData = newValue } }
    @State var latestBottomConfirmedSeq: Int64 = 0
    @State var chatEntryStabilizationUntil = Date.distantPast
    @State var didUserInteractWithMessageScroll = false
    @State var selectedUserProfile: IMUser?
    @State var selectedSenderActionUser: IMUser?
    // WDT_IOS1_CHAT_STATE_20261023_BEGIN
    var selectedAttachmentMessage: ChatMessage? {
        get { messagePresentation.selectedAttachmentMessage }
        nonmutating set { messagePresentation.selectedAttachmentMessage = newValue }
    }
    // WDT_IOS1_CHAT_STATE_20261023_END
    @State var previewImageAttachment: AttachmentMediaPreviewItem?
    @State var previewVideoAttachment: AttachmentMediaPreviewItem?
    @State var attachmentShareItem: AttachmentShareItem?
    @State var attachmentPreviewDocument: AttachmentLocalPreviewDocument?
    var showSearch: Bool { get { presentation.showSearch } nonmutating set { presentation.showSearch = newValue } }
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    @State var historySearchSession = ChatHistorySearchSession()
    @State var pendingHistorySearchJump: ChatHistorySearchJump?
    @State var historySearchJumpTask: Task<Void, Never>?
    @State var historySearchJumpGeneration: UInt64 = 0
    @State var openHistorySearchAfterGroupDetail = false
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    @State var didApplyInitialSearchJumpTarget = false
    @State var isPreparingInitialSearchJumpTarget = false
    @State var linkedConversationRoute: ChatLinkedConversationRoute?
    @State var pendingProfileConversationID: String?
    var oldestHistoryLoadAnchorID: String? { get { presentation.oldestHistoryLoadAnchorID } nonmutating set { presentation.oldestHistoryLoadAnchorID = newValue } }
    var oldestHistoryLoadAnchorMinY: CGFloat? { get { presentation.oldestHistoryLoadAnchorMinY } nonmutating set { presentation.oldestHistoryLoadAnchorMinY = newValue } }
    var newestHistoryLoadAnchorSeq: Int64 { get { presentation.newestHistoryLoadAnchorSeq } nonmutating set { presentation.newestHistoryLoadAnchorSeq = newValue } }
    var didTriggerOlderHistoryLoadForScrollIntent: Bool { get { presentation.didTriggerOlderHistoryLoadForScrollIntent } nonmutating set { presentation.didTriggerOlderHistoryLoadForScrollIntent = newValue } }
    @StateObject var transcriptScrollControl = ChatTranscriptScrollControl()
    @GestureState var isTranscriptDragRecognized = false
    @State var scrollStateConversationID: String?
    @State var scrollStateSessionKey = ""
    @State var scrollArbiter = ConversationScrollArbiter()
    @State var pendingScrollTargetSource: ConversationScrollRequestSource = .searchJump
    @State var pendingScrollTargetAnchor: UnitPoint = .center
    @StateObject var messageTopMeasurements = ChatMessageTopMeasurementStore()
    @StateObject var scrollMetricsMeasurements = ChatScrollMetricsMeasurementStore()
    @State var mediaScrollActivity = ChatMediaScrollActivity()
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
    @StateObject var timelineViewModel = ChatTimelineViewModel()
    @StateObject var transcriptProjectionCache = ChatTranscriptProjectionCache()
    var cachedMessageRows: [MessageRowModel] { timelineViewModel.rows }
    var cachedMessageRowsSource: [ChatMessage] { timelineViewModel.source }
    var cachedMessageRowsConversationID: String { timelineViewModel.context?.conversationID ?? "" }
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END
    var isApplyingInitialScroll: Bool { get { presentation.isApplyingInitialScroll } nonmutating set { presentation.isApplyingInitialScroll = newValue } }
    var isUserBrowsingHistory: Bool { get { presentation.isUserBrowsingHistory } nonmutating set { presentation.isUserBrowsingHistory = newValue } }
    var isAtBottom: Bool { get { presentation.isAtBottom } nonmutating set { presentation.isAtBottom = newValue } }
    var pendingOwnSendScrollBaselineCount: Int? { get { presentation.pendingOwnSendScrollBaselineCount } nonmutating set { presentation.pendingOwnSendScrollBaselineCount = newValue } }
    var didScrollTowardUnreadMessages: Bool { get { presentation.didScrollTowardUnreadMessages } nonmutating set { presentation.didScrollTowardUnreadMessages = newValue } }
    @State var isClearingUnreadReminder = false
    var lastScrollVisibility: ChatScrollVisibility { get { presentation.lastScrollVisibility } nonmutating set { presentation.lastScrollVisibility = newValue } }
    var underfilledOlderAutofillAttempts: Int { get { presentation.underfilledOlderAutofillAttempts } nonmutating set { presentation.underfilledOlderAutofillAttempts = newValue } }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var pendingMentionAll: Bool {
        get { composerState.draft.mentionAll }
        nonmutating set { composerState.draft.mentionAll = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var pendingMentionUsers: [MentionIdentity] {
        get { composerState.draft.externalMentions }
        nonmutating set { composerState.draft.externalMentions = newValue }
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
    @State var messageRenderCacheRefreshTask: Task<Void, Never>?
    @State var lastOlderHistoryLoadAttemptAt = Date.distantPast
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END
    @State var lastVisibleReadAckToken = ""
    @State var chatOpenStartedAt = CFAbsoluteTimeGetCurrent()
    @State var chatOpenPerfConversationID: String?
    @State var didLogChatFirstFrame = false
    @State var didLogChatHistoryReady = false
    @State var didLogChatSideDataReady = false
    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_STATE - 修改开始：定位图片发送后返回偶发卡住的 UI 链路日志状态
    @State var chatBackDismissAttemptID = 0
    @State var chatBackDisappearedAttemptID = 0
    @State var chatBackDismissAttemptStartedAt = CFAbsoluteTimeGetCurrent()
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110: removed the replaced token-refresh diagnostic sequence.
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_STATE - 修改结束：定位图片发送后返回偶发卡住的 UI 链路日志状态
    let bottomAnchorID = "chat-bottom-anchor"
    let messageListBottomAnchorHeight: CGFloat = 24
    let firstUnreadMarkerID = "first-unread-marker"
    let initialUnreadAnchorMaxHistoryLoads = 1
    let maxUnderfilledOlderAutofillAttempts = 3
    let automaticBottomScrollSuppressionInterval: TimeInterval = 1.6
    let chatEntryStabilizationDuration: TimeInterval = 3.0

    var chatScrollCoordinateSpaceName: String {
        "chat-scroll-\(conversationID)"
    }

    var conversation: ConversationMessageSnapshot {
        screenStores.conversations.conversationMessagePresentation(id: conversationID)
            ?? screenActions.authority.conversationFallback(conversationID)
    }

    // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
    var batchForwardSelectedSourceIDs: Set<String> {
        if let selection = observedBatchForwardSelection, selection.conversationID == conversationID {
            return selection.ids
        }
        return screenStores.batchForward.draft(for: conversationID)?.selectedSourceIDs ?? []
    }

    var isBatchForwardSelectionActive: Bool { !batchForwardSelectedSourceIDs.isEmpty }
    var batchForwardSelectedSourceCount: Int { batchForwardSelectedSourceIDs.count }
    // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END

    func batchForwardDisabledReason(for message: ChatMessage, policy: MessageActionsPolicy? = nil) -> String? { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        switch screenActions.forwarding.batchForwardEligibility(for: message, in: conversationID, policy: policy ?? observedTenantChatPolicy?.actions) { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        case .selectable:
            return nil
        case .disabled(let reason):
            return reason
        }
    }

    func beginBatchForward(with message: ChatMessage) {
        screenActions.forwarding.beginBatchForward(
            conversationID: conversationID,
            initialMessageID: message.id
        )
    }

    var chatEnterpriseName: String { observedEnterpriseName ?? screenStores.enterpriseMembership.snapshot.current.name } // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
    var showsChatGroupMemberCount: Bool { observedGroupCountVisibility ?? screenActions.authority.initialGroupCount() } // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
    // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110
    var observedTimelinePolicy: TenantInteractionPresentationStore.ChatPolicy? { observedTenantChatPolicy }
    var showsChatProcessingNotices: Bool { observedTenantChatPolicy?.showsProcessingNotices ?? screenActions.authority.processingNotices() } // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110

    var transcriptProjection: (timeline: [ChatMessage], pinned: [ChatMessage]) {
        transcriptProjectionCache.projection(
            for: conversation.messages,
            showsProcessingNotices: showsChatProcessingNotices // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        )
    }

    var pinnedMessages: [ChatMessage] {
        transcriptProjection.pinned
    }

    var timelineMessages: [ChatMessage] {
        transcriptProjection.timeline
    }

    var body: some View {
#if DEBUG
        let _ = ChatTimelineRenderDiagnostics.chatBody?(self) // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110
#endif
        let user = chatCurrentUser // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        // WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111_BEGIN
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
        return ChatProtectedScreen(
            initiallyAuthorized: screenActions.authority.protectedChatInitial(),
            authorizationUpdates: screenActions.authority.protectedChatUpdates(),
            authenticate: { _ = await screenActions.authority.authorizeChat() }
        ) {
            // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
            // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_BEGIN
            // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
            // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110_BEGIN
            ContactDirectoryPresentationView(store: screenStores.contacts) {
                let store = screenStores.conversations
                PublisherSnapshotView(
                    initialValue: store.chatAvailability(for: conversationID),
                    updates: store.chatAvailabilityUpdates(for: conversationID)
                ) { _ in
                    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_BEGIN
                    store.observeConversationPresentation(id: conversationID) { snapshot in
                        // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_BEGIN
                        observedUnlockedBody
                            .environment(\.currentUserDisplay, user) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
                            .environment(\.enterpriseDisplayName, chatEnterpriseName) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
                            .environment(\.tenantShowsGroupMemberCount, showsChatGroupMemberCount) // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
                            .environment(\.chatShowsMessageProcessingNotices, showsChatProcessingNotices).environment(\.chatRenderingShowsMessageProcessingNotices, showsChatProcessingNotices) // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                            .chatTranscriptConversation(snapshot ?? conversation, replyLookup: transcriptProjectionCache.replySourceLookup)
                        // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_END
                    }
                    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_END
                }
            }
            // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110_END
            // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END
            // WDT_IOS1_REFACTOR_CONTACT_PRESENTATION_OBSERVATION_20261110_END
        }
        // WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111_END
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_BEGIN
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_BEGIN
        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_BEGIN
        // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
        .onAppear { activateComposerDraft() }
        .onChangeCompat(of: conversationID) { _, _ in activateComposerDraft() }
        .onChangeCompat(of: chatComposerScope) { _, _ in activateComposerDraft() }
        .onReceive(screenStores.sessionIdentity.updates.map(\.scope).removeDuplicates()) { scope in
            if observedComposerScope != scope { observedComposerScope = scope }
        }
        // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END
        .onReceive(screenStores.currentUser.updates(on: CurrentUserPresentationStore.display)) { user in
            if observedCurrentUser != user { observedCurrentUser = user }
        } // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        .onReceive(screenStores.enterpriseMembership.updates(\.current.name)) { name in
            if observedEnterpriseName != name { observedEnterpriseName = name }
        }
        // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110_END
        .onReceive(screenStores.tenantClientPolicy.updates(\.showsGroupMemberCount)) { visible in
            if observedGroupCountVisibility != visible { observedGroupCountVisibility = visible }
        }
        // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110_END
        .onReceive(screenStores.tenantInteraction.updates(\.chat)) { policy in // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
            if observedTenantChatPolicy != policy { observedTenantChatPolicy = policy }
        }
        .onReceive(screenStores.batchForward.selectionUpdates(for: conversationID)) { selection in
            if selection != observedBatchForwardSelection { observedBatchForwardSelection = selection }
        }
        // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110_END
    }

    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_BEGIN
    var chatComposerScope: [String?] {
        observedComposerScope ?? screenActions.authority.composerScope()
    }
    func activateComposerDraft() {
        composerState.activate(scope: screenActions.authority.composerScope(), conversationID: conversationID)
    }
    // WDT_IOS1_REFACTOR_COMPOSER_STATE_20261110_END

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
    @ViewBuilder
    private var observedUnlockedBody: some View {
        let identities = blacklistPeerIdentities
        // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_BEGIN
        let groupSelectors = screenActions.authority.groupObservationSelectors(conversationID: conversationID)
        if !groupSelectors.isEmpty {
            GroupSnapshotView(store: screenStores.contacts, selectors: groupSelectors) { unlockedBody }
        } else if identities.isEmpty {
            unlockedBody
        // WDT_IOS1_REFACTOR_GROUP_RELAY_OBSERVATION_20261110_END
        } else {
            let store = screenStores.contacts
            PublisherSnapshotView(
                // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
                initialValue: store.callRelationshipSnapshot(matching: identities),
                updates: store.callRelationshipUpdates(matching: identities)
            ) { _ in
                unlockedBody
            }
        }
    }
    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END

}

// WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_BEGIN
extension ConversationStore {
    @MainActor
    func observeConversationPresentation<Content: View>(
        id: String,
        @ViewBuilder content: @escaping (ConversationMessageSnapshot?) -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: conversationMessagePresentation(id: id),
            updates: conversationMessageUpdates(id: id),
            content: content
        )
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
    @MainActor
    func observeConversationCollection<Selection: Equatable, Content: View>(
        _ select: @escaping ([Conversation]) -> Selection,
        @ViewBuilder content: @escaping (Selection) -> Content
    ) -> some View {
        PublisherSnapshotView(
            initialValue: select(conversations),
            updates: conversationUpdates.map(select).removeDuplicates().eraseToAnyPublisher(), // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            content: content
        )
    }
    // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
}
// WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_END

// WDT_IOS1_CHAT_PROTECTED_ENTRY_FEATURE_20261111: the shared lock screen now comes from IM4Features.
typealias SheetHeader = IM4DesignSystem.SheetHeader // WDT_IOS1_FEATURES_ATTACHMENT_ADMISSION_MODULE_20261110 // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_FEATURE_ROUTING_20261110_END

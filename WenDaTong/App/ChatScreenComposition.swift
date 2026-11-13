import Combine
import IM4Domain
import IM4Features
import IM4Stores
import SwiftUI

// WDT_IOS1_CHAT_SCREEN_ACTION_BOUNDARIES_20261111_BEGIN
// The page receives operation-specific commands and live authority queries.
// App construction keeps the original service calls and scope guards.
@MainActor
final class ChatScreenActionsSource {
    private let assemble: () -> ChatScreenActions
    private(set) lazy var actions = assemble()

    init(assemble: @escaping () -> ChatScreenActions) {
        self.assemble = assemble
    }
}

@MainActor
struct ChatScreenActions {
    let authority: ChatScreenAuthority
    let people: ChatPeopleQueries
    let calls: ChatCallActions
    let forwarding: ChatForwardingActions
    let history: ChatHistoryActions
    let messages: ChatMessageActions
    let media: ChatMediaActions
    let search: ChatHistorySearchActions
    let toast: (String?) -> Void

    static func bind(_ app: AppState) -> Self {
        Self(
            authority: .bind(app),
            people: .bind(app),
            calls: .bind(app),
            forwarding: .bind(app),
            history: .bind(app),
            messages: .bind(app),
            media: .bind(app),
            search: .bind(app),
            toast: app.setToast
        )
    }
}

@MainActor
struct ChatScreenAuthority {
    let conversationFallback: (String) -> ConversationMessageSnapshot
    private let performGroupObservationSelectors: (String) -> [ContactStore.GroupSelector]
    let initialGroupCount: () -> Bool
    let processingNotices: () -> Bool
    let protectedChatInitial: () -> Bool
    let protectedChatUpdates: () -> AnyPublisher<Bool, Never>
    let authorizeChat: () async -> Bool
    let authorizeFilePreview: () async -> Bool
    let chatBubbleSessionIdentity: () -> ChatBubbleSessionIdentity
    let composerScope: () -> [String?]
    let sessionGeneration: () -> UInt64

    static func bind(_ app: AppState) -> Self {
        Self(
            conversationFallback: { app.conversation(id: $0) },
            performGroupObservationSelectors: app.groupObservationSelectors,
            initialGroupCount: { app.shouldShowGroupMemberCount },
            processingNotices: { app.shouldShowMessageProcessingNotices },
            protectedChatInitial: { app.isProtectedAccessAuthorized(.chat) },
            protectedChatUpdates: { app.protectedAccessUpdates(for: .chat) },
            authorizeChat: { await app.authorizeProtectedAccess(.chat) },
            authorizeFilePreview: { await app.authorizeProtectedAccess(.filePreview) },
            chatBubbleSessionIdentity: { app.chatBubbleSessionIdentity },
            composerScope: {
                let api = app.apiContext
                return [api.accountID, api.tenantID, api.appID, api.imUID, api.deviceID]
            },
            sessionGeneration: { app.localMessageSessionGeneration }
        )
    }

    func groupObservationSelectors(conversationID: String) -> [ContactStore.GroupSelector] {
        performGroupObservationSelectors(conversationID)
    }
}

@MainActor
struct ChatPeopleQueries {
    let globalMutedMessage: String
    private let performDirectConversationCallPeer: (ConversationMessageSnapshot) -> IMUser?
    private let performDirectConversationProfilePeer: (ConversationMessageSnapshot) -> IMUser?
    private let performDirectPeerID: (ConversationMessageSnapshot) -> String?
    private let performUserIdentityCandidates: (IMUser) -> [String]
    private let performRemarkPreferredDisplayName: (IMUser) -> String
    private let performGroup: (String) -> GroupInfo?
    private let performGroupMemberProfileCacheKey: (String) -> String
    private let performMyGroupMemberProjection: (String) -> IMUser?
    private let performGroupMemberCount: (Int?, Int?, Bool) -> Int?
    let conversationSendDisabledReason: (String) -> String
    let conversationFriendRequestActionTitle: (String) -> String?
    let applyFriendFromDisabledConversation: (String) async -> Void
    private let performCanCurrentUserSend: (GroupInfo) -> Bool
    let canManageGroup: (GroupInfo) -> Bool
    let isCurrentMessageSender: (String) -> Bool
    private let readCurrentUnreadAnnouncement: (String) -> GroupAnnouncement?
    private let performHasUnreadAnnouncement: (String) -> Bool
    private let performLoadGroupAnnouncementDetail: (String, String, Bool, ((Bool) -> Void)?) -> Void
    private let performMarkGroupAnnouncementRead: (String, String, ((Bool) -> Void)?) -> Void

    static func bind(_ app: AppState) -> Self {
        Self(
            globalMutedMessage: AppState.globalMutedMessage,
            performDirectConversationCallPeer: { app.directConversationCallPeer(for: $0) },
            performDirectConversationProfilePeer: { app.directConversationProfilePeer(for: $0) },
            performDirectPeerID: app.directPeerID,
            performUserIdentityCandidates: app.userIdentityCandidates,
            performRemarkPreferredDisplayName: { app.remarkPreferredDisplayName(for: $0) },
            performGroup: { app.group(forConversationID: $0) },
            performGroupMemberProfileCacheKey: { app.groupMemberProfileCacheKey(groupID: $0) },
            performMyGroupMemberProjection: app.myGroupMemberProjection,
            performGroupMemberCount: { app.visibleGroupMemberCount($0, $1, showsCount: $2) },
            conversationSendDisabledReason: app.conversationSendDisabledReason,
            conversationFriendRequestActionTitle: app.conversationFriendRequestActionTitle,
            applyFriendFromDisabledConversation: app.applyFriendFromDisabledConversation,
            performCanCurrentUserSend: { app.canCurrentUserSend(in: $0) },
            canManageGroup: app.canManageGroup,
            isCurrentMessageSender: app.isCurrentMessageSender,
            readCurrentUnreadAnnouncement: app.currentUnreadAnnouncement,
            performHasUnreadAnnouncement: app.hasUnreadAnnouncement,
            performLoadGroupAnnouncementDetail: app.loadGroupAnnouncementDetail,
            performMarkGroupAnnouncementRead: app.markGroupAnnouncementRead
        )
    }

    func directConversationCallPeer(for conversation: ConversationMessageSnapshot) -> IMUser? {
        performDirectConversationCallPeer(conversation)
    }

    func directConversationProfilePeer(for conversation: ConversationMessageSnapshot) -> IMUser? {
        performDirectConversationProfilePeer(conversation)
    }

    func directPeerID(for conversation: ConversationMessageSnapshot) -> String? {
        performDirectPeerID(conversation)
    }

    func userIdentityCandidates(for user: IMUser) -> [String] {
        performUserIdentityCandidates(user)
    }

    func remarkPreferredDisplayName(for user: IMUser) -> String {
        performRemarkPreferredDisplayName(user)
    }

    func group(forConversationID conversationID: String) -> GroupInfo? {
        performGroup(conversationID)
    }

    func groupMemberProfileCacheKey(groupID: String) -> String {
        performGroupMemberProfileCacheKey(groupID)
    }

    func myGroupMemberProjection(groupID: String) -> IMUser? {
        performMyGroupMemberProjection(groupID)
    }

    func groupMemberCount(first: Int?, second: Int?, showsCount: Bool) -> Int? {
        performGroupMemberCount(first, second, showsCount)
    }

    func canCurrentUserSend(in group: GroupInfo) -> Bool {
        performCanCurrentUserSend(group)
    }

    func currentUnreadAnnouncement(for groupID: String) -> GroupAnnouncement? {
        readCurrentUnreadAnnouncement(groupID)
    }

    func hasUnreadAnnouncement(for groupID: String) -> Bool {
        performHasUnreadAnnouncement(groupID)
    }

    func loadGroupAnnouncementDetail(groupID: String, announcementID: String, silent: Bool = true, completion: ((Bool) -> Void)? = nil) {
        performLoadGroupAnnouncementDetail(groupID, announcementID, silent, completion)
    }

    func markGroupAnnouncementRead(groupID: String, announcementID: String, completion: ((Bool) -> Void)? = nil) {
        performMarkGroupAnnouncementRead(groupID, announcementID, completion)
    }
}

@MainActor
struct ChatCallActions {
    private let performCanStartVoiceCall: (IMUser) -> Bool
    private let performCanStartVideoCall: (IMUser) -> Bool
    private let performCallLicenseUnavailableMessage: (RTCCapabilityMedia) -> String?
    private let performVoiceCallUnavailableReason: (IMUser) -> String?
    private let performVideoCallUnavailableReason: (IMUser) -> String?
    let guardCallLicenseForAction: (RTCCapabilityMedia) -> Bool
    private let performStartOutgoingVoiceCall: (IMUser, String) -> Void
    private let performStartOutgoingVideoCall: (IMUser, String, Bool) -> Void

    static func bind(_ app: AppState) -> Self {
        Self(
            performCanStartVoiceCall: app.canStartVoiceCall,
            performCanStartVideoCall: app.canStartVideoCall,
            performCallLicenseUnavailableMessage: app.callLicenseUnavailableMessage,
            performVoiceCallUnavailableReason: app.voiceCallUnavailableReason,
            performVideoCallUnavailableReason: app.videoCallUnavailableReason,
            guardCallLicenseForAction: app.guardCallLicenseForAction,
            performStartOutgoingVoiceCall: { app.startOutgoingVoiceCall(to: $0, channelID: $1) },
            performStartOutgoingVideoCall: { app.startOutgoingVideoCall(to: $0, channelID: $1, presentImmediately: $2) }
        )
    }

    func canStartVoiceCall(with user: IMUser) -> Bool {
        performCanStartVoiceCall(user)
    }

    func canStartVideoCall(with user: IMUser) -> Bool {
        performCanStartVideoCall(user)
    }

    func callLicenseUnavailableMessage(for media: RTCCapabilityMedia) -> String? {
        performCallLicenseUnavailableMessage(media)
    }

    func voiceCallUnavailableReason(for user: IMUser) -> String? {
        performVoiceCallUnavailableReason(user)
    }

    func videoCallUnavailableReason(for user: IMUser) -> String? {
        performVideoCallUnavailableReason(user)
    }

    func startOutgoingVoiceCall(to peer: IMUser, channelID: String) {
        performStartOutgoingVoiceCall(peer, channelID)
    }

    func startOutgoingVideoCall(to peer: IMUser, channelID: String, presentImmediately: Bool) {
        performStartOutgoingVideoCall(peer, channelID, presentImmediately)
    }
}

@MainActor
struct ChatForwardingActions {
    private let performBatchForwardEligibility: (ChatMessage, String, MessageActionsPolicy?) -> BatchForwardEligibility
    private let performBeginBatchForward: (String, String) -> Void
    let cancelBatchForward: () -> Void
    private let performRefreshBatchForwardContext: (String) -> Void
    private let performRefreshBatchForwardSource: (String, ConversationMessageSnapshot?) -> Void
    private let performRefreshBatchForwardTargets: (String, [Conversation]) -> Void
    private let performToggleBatchForwardSource: (String, String) -> Void
    let leaveBatchForwardSourceConversation: (String) -> Void

    static func bind(_ app: AppState) -> Self {
        Self(
            performBatchForwardEligibility: app.batchForwardEligibility,
            performBeginBatchForward: app.beginBatchForward,
            cancelBatchForward: app.cancelBatchForward,
            performRefreshBatchForwardContext: { app.refreshBatchForwardContext(conversationID: $0) },
            performRefreshBatchForwardSource: app.refreshBatchForwardSource,
            performRefreshBatchForwardTargets: app.refreshBatchForwardTargets,
            performToggleBatchForwardSource: app.toggleBatchForwardSource,
            leaveBatchForwardSourceConversation: app.leaveBatchForwardSourceConversation
        )
    }

    func batchForwardEligibility(for message: ChatMessage, in conversationID: String, policy: MessageActionsPolicy?) -> BatchForwardEligibility {
        performBatchForwardEligibility(message, conversationID, policy)
    }

    func beginBatchForward(conversationID: String, initialMessageID: String) {
        performBeginBatchForward(conversationID, initialMessageID)
    }

    func refreshBatchForwardContext(conversationID: String) {
        performRefreshBatchForwardContext(conversationID)
    }

    func refreshBatchForwardSource(conversationID: String, source: ConversationMessageSnapshot?) {
        performRefreshBatchForwardSource(conversationID, source)
    }

    func refreshBatchForwardTargets(conversationID: String, conversations: [Conversation]) {
        performRefreshBatchForwardTargets(conversationID, conversations)
    }

    func toggleBatchForwardSource(messageID: String, conversationID: String) {
        performToggleBatchForwardSource(messageID, conversationID)
    }
}

@MainActor
struct ChatHistoryActions {
    let activeConversationHistoryScope: () -> String
    private let performRememberedConversationBottomSeq: (String) -> Int64
    private let performRememberConversationBottomSeq: (Int64, String) -> Void
    let isConversationMessageSyncInFlight: (String) -> Bool
    private let performLoadOlderMessagesIfAvailable: (String, @escaping @MainActor () async -> Bool) -> Bool
    let hasNewerMessagesAvailable: (String) -> Bool
    let loadNewerMessagesIfAvailable: (String) -> Void
    private let performMarkConversationRead: (String, Int64?, Bool, ((Bool) -> Void)?) -> Void
    private let performUpdateRealtimeConversationAutoRead: (String, Bool) -> Void
    let subscribeRealtimeConversation: (String) -> Void
    let leaveRealtimeConversation: (String) -> Void
    private let performLoadGroupDetailForConversation: (String, Bool, Bool) -> Void
    let prepareConversationTailWindowForEntry: (String) -> Void
    private let performSyncConversationMessagesIfNeeded: (String, Bool, Bool, Bool, Bool) -> Void
    let scheduleWarmConversationRefreshAfterInitialRender: (String) -> Void
    let syncReadReceiptsIfNeeded: (String) -> Void
    private let performRefreshPinnedMessages: (String, Bool) -> Void
    let shouldPollConversation: (String) -> Bool
    private let performRemoteChannelID: (ConversationMessageSnapshot) -> String

    static func bind(_ app: AppState) -> Self {
        Self(
            activeConversationHistoryScope: { app.activeConversationHistoryScope },
            performRememberedConversationBottomSeq: app.rememberedConversationBottomSeq,
            performRememberConversationBottomSeq: app.rememberConversationBottomSeq,
            isConversationMessageSyncInFlight: app.isConversationMessageSyncInFlight,
            performLoadOlderMessagesIfAvailable: app.loadOlderMessagesIfAvailable,
            hasNewerMessagesAvailable: app.hasNewerMessagesAvailable,
            loadNewerMessagesIfAvailable: app.loadNewerMessagesIfAvailable,
            performMarkConversationRead: app.markConversationRead,
            performUpdateRealtimeConversationAutoRead: app.updateRealtimeConversationAutoRead,
            subscribeRealtimeConversation: app.subscribeRealtimeConversation,
            leaveRealtimeConversation: app.leaveRealtimeConversation,
            performLoadGroupDetailForConversation: app.loadGroupDetailForConversation,
            prepareConversationTailWindowForEntry: app.prepareConversationTailWindowForEntry,
            performSyncConversationMessagesIfNeeded: { app.syncConversationMessagesIfNeeded($0, force: $1, silent: $2, showLoadingIndicator: $3, trimToLatestWindow: $4) },
            scheduleWarmConversationRefreshAfterInitialRender: app.scheduleWarmConversationRefreshAfterInitialRender,
            syncReadReceiptsIfNeeded: app.syncReadReceiptsIfNeeded,
            performRefreshPinnedMessages: app.refreshPinnedMessages,
            shouldPollConversation: app.shouldPollConversation,
            performRemoteChannelID: { app.remoteChannelID(for: $0) }
        )
    }

    func rememberedConversationBottomSeq(for conversationID: String) -> Int64 {
        performRememberedConversationBottomSeq(conversationID)
    }

    func rememberConversationBottomSeq(_ seq: Int64, for conversationID: String) {
        performRememberConversationBottomSeq(seq, conversationID)
    }

    @discardableResult
    func loadOlderMessagesIfAvailable(_ conversationID: String, waitForViewportIdle: @escaping @MainActor () async -> Bool = { true }) -> Bool {
        performLoadOlderMessagesIfAvailable(conversationID, waitForViewportIdle)
    }

    func markConversationRead(_ conversationID: String, throughSeq: Int64? = nil, showToast: Bool = true, completion: ((Bool) -> Void)? = nil) {
        performMarkConversationRead(conversationID, throughSeq, showToast, completion)
    }

    func updateRealtimeConversationAutoRead(_ conversationID: String, canAutoRead: Bool) {
        performUpdateRealtimeConversationAutoRead(conversationID, canAutoRead)
    }

    func loadGroupDetailForConversation(_ conversationID: String, force: Bool, includeSecondaryData: Bool) {
        performLoadGroupDetailForConversation(conversationID, force, includeSecondaryData)
    }

    func syncConversationMessagesIfNeeded(
        _ conversationID: String,
        force: Bool = false,
        silent: Bool = false,
        showLoadingIndicator: Bool = true,
        trimToLatestWindow: Bool = false
    ) {
        performSyncConversationMessagesIfNeeded(conversationID, force, silent, showLoadingIndicator, trimToLatestWindow)
    }

    func refreshPinnedMessages(for conversationID: String, silent: Bool = true) {
        performRefreshPinnedMessages(conversationID, silent)
    }

    func remoteChannelID(for conversation: ConversationMessageSnapshot) -> String {
        performRemoteChannelID(conversation)
    }
}

@MainActor
struct ChatMessageActions {
    private let performSendText: (String, String, String?, MessageReplyContext?, Bool, [MentionIdentity], (@MainActor () -> Void)?) -> Bool
    private let performCanAdminDeleteMessage: (ChatMessage, String) -> Bool
    private let performAdminDeleteMessageForAll: (String, String) -> Void
    private let performMessageEditUnavailableReason: (ChatMessage, MessageActionsPolicy?) -> String?
    private let performMessageRecallUnavailableReason: (ChatMessage, MessageActionsPolicy?) -> String?
    private let performAddReaction: (String, String, String) -> Void
    let copyMessage: (ChatMessage) -> Void
    private let performPrepareReadReceiptPanel: (String, String) -> Task<Void, Never>
    private let performToggleMessagePinned: (String, String) -> Void
    private let performToggleMessageFavorite: (String, String) -> Void
    private let performDeleteOwnMessage: (String, String, OwnMessageDeletion) async -> Void
    private let performRecallMessage: (String, String) -> Void
    let messageEditCurrentConversationID: () -> String?
    private let performRefreshAppInteractionPolicy: (Bool) -> Void

    static func bind(_ app: AppState) -> Self {
        Self(
            performSendText: app.sendText,
            performCanAdminDeleteMessage: app.canAdminDeleteMessage,
            performAdminDeleteMessageForAll: app.adminDeleteMessageForAll,
            performMessageEditUnavailableReason: app.messageEditUnavailableReason,
            performMessageRecallUnavailableReason: app.messageRecallUnavailableReason,
            performAddReaction: app.addReaction,
            copyMessage: app.copyMessage,
            performPrepareReadReceiptPanel: app.prepareReadReceiptPanel,
            performToggleMessagePinned: app.toggleMessagePinned,
            performToggleMessageFavorite: app.toggleMessageFavorite,
            performDeleteOwnMessage: app.deleteOwnMessage,
            performRecallMessage: app.recallMessage,
            messageEditCurrentConversationID: { app.messageEditCurrentConversationID },
            performRefreshAppInteractionPolicy: app.refreshAppInteractionPolicy
        )
    }

    func sendText(
        _ text: String,
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext?,
        mentionAll: Bool,
        mentionedUsers: [MentionIdentity],
        onPolicyRejected: (@MainActor () -> Void)?
    ) -> Bool {
        performSendText(text, conversationID, quote, replyContext, mentionAll, mentionedUsers, onPolicyRejected)
    }

    func canAdminDeleteMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        performCanAdminDeleteMessage(message, conversationID)
    }

    func adminDeleteMessageForAll(messageID: String, in conversationID: String) {
        performAdminDeleteMessageForAll(messageID, conversationID)
    }

    func messageEditUnavailableReason(_ message: ChatMessage, policy: MessageActionsPolicy?) -> String? {
        performMessageEditUnavailableReason(message, policy)
    }

    func messageRecallUnavailableReason(_ message: ChatMessage, policy: MessageActionsPolicy?) -> String? {
        performMessageRecallUnavailableReason(message, policy)
    }

    func addReaction(_ emoji: String, to messageID: String, in conversationID: String) {
        performAddReaction(emoji, messageID, conversationID)
    }

    @discardableResult
    func prepareReadReceiptPanel(messageID: String, in conversationID: String) -> Task<Void, Never> {
        performPrepareReadReceiptPanel(messageID, conversationID)
    }

    func toggleMessagePinned(messageID: String, in conversationID: String) {
        performToggleMessagePinned(messageID, conversationID)
    }

    func toggleMessageFavorite(messageID: String, in conversationID: String) {
        performToggleMessageFavorite(messageID, conversationID)
    }

    func deleteOwnMessage(messageID: String, in conversationID: String, as deletion: OwnMessageDeletion) async {
        await performDeleteOwnMessage(messageID, conversationID, deletion)
    }

    func recallMessage(messageID: String, in conversationID: String) {
        performRecallMessage(messageID, conversationID)
    }

    func refreshAppInteractionPolicy(force: Bool) {
        performRefreshAppInteractionPolicy(force)
    }
}

@MainActor
struct ChatMediaActions {
    let canRetryAttachmentUpload: (ChatMessage) -> Bool
    private let performAttachmentMediaCategory: (ChatMessage) -> String
    private let performPrepareMessageAttachmentLocalFile: (ChatMessage, String, Bool) async throws -> URL
    private let performResolvedAttachmentDownloadURL: (ChatMessage) -> URL?
    private let performResolvedAttachmentBestPreviewURL: (ChatMessage) -> URL?
    let attachmentCanRefreshRemoteFile: (ChatMessage) -> Bool
    private let performAttachmentIdentity: (ChatMessage) -> FileStore.ChatAttachmentIdentity?

    static func bind(_ app: AppState) -> Self {
        Self(
            canRetryAttachmentUpload: app.canRetryAttachmentUpload,
            performAttachmentMediaCategory: app.attachmentMediaCategory,
            performPrepareMessageAttachmentLocalFile: { try await app.prepareMessageAttachmentLocalFile($0, conversationID: $1, preferPreview: $2) },
            performResolvedAttachmentDownloadURL: app.resolvedAttachmentDownloadURL,
            performResolvedAttachmentBestPreviewURL: app.resolvedAttachmentBestPreviewURL,
            attachmentCanRefreshRemoteFile: app.attachmentCanRefreshRemoteFile,
            performAttachmentIdentity: app.chatAttachmentIdentity
        )
    }

    func attachmentMediaCategory(for message: ChatMessage) -> String {
        performAttachmentMediaCategory(message)
    }

    func prepareMessageAttachmentLocalFile(_ message: ChatMessage, conversationID: String, preferPreview: Bool) async throws -> URL {
        try await performPrepareMessageAttachmentLocalFile(message, conversationID, preferPreview)
    }

    func resolvedAttachmentDownloadURL(for message: ChatMessage) -> URL? {
        performResolvedAttachmentDownloadURL(message)
    }

    func resolvedAttachmentBestPreviewURL(for message: ChatMessage) -> URL? {
        performResolvedAttachmentBestPreviewURL(message)
    }

    func attachmentIdentity(for message: ChatMessage) -> FileStore.ChatAttachmentIdentity? {
        performAttachmentIdentity(message)
    }
}

@MainActor
struct ChatHistorySearchActions {
    private let performPrepareMessageJump: (String, Int64, String) async -> String?
    private let performPrepareSearchJumpTarget: (RemoteTenantSearchJumpTarget, String) async -> String?
    let postTenantSearchEvent: (TenantSearchAnalyticsEvent) -> Void
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    let searchHistory: (String?, ChatBubbleSessionIdentity) -> [String]
    let recordSearch: (String, String?, ChatBubbleSessionIdentity) -> Void
    let removeSearch: (String, String?, ChatBubbleSessionIdentity) -> Void
    let clearSearches: (String?, ChatBubbleSessionIdentity) -> Void
    let searchPage: (ChatHistorySearchRequest, String) async -> TenantSearchOutcome
    let visibleHits: ([RemoteTenantSearchResult], String) -> [RemoteTenantSearchResult]
    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113
    let dateMessages: (String, [DateInterval], Set<String>, Set<Int64>) async -> [ChatMessage]
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END

    static func bind(_ app: AppState) -> Self {
        Self(
            performPrepareMessageJump: app.prepareMessageJump,
            performPrepareSearchJumpTarget: app.prepareSearchJumpTarget,
            postTenantSearchEvent: app.postTenantSearchEvent,
            // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
            searchHistory: app.recentTenantSearches,
            recordSearch: app.recordTenantSearch,
            removeSearch: app.removeTenantSearch,
            clearSearches: app.clearTenantSearchHistory,
            searchPage: { request, conversationID in
                await app.tenantSearch(query: request.keyword, scope: "conversation", types: request.types,
                    limit: 20, cursorV2: request.cursorV2, typeCursors: request.legacyCursors,
                    conversationID: conversationID, fromUID: request.sender, startAt: request.startAt,
                    endAt: request.endAt, fileType: request.fileType, hasLink: request.hasLink,
                    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_BEGIN
                    messageContent: request.messageContent) // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113
            },
            visibleHits: app.visibleConversationSearchHits,
            dateMessages: app.conversationSearchDateMessages
                    // WDT_IOS1_CHAT_SEARCH_CALENDAR_20261113_END
            // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        )
    }

    func prepareMessageJump(messageID: String, channelSeq: Int64, conversationID: String) async -> String? {
        await performPrepareMessageJump(messageID, channelSeq, conversationID)
    }

    func prepareSearchJumpTarget(_ target: RemoteTenantSearchJumpTarget, conversationID: String) async -> String? {
        await performPrepareSearchJumpTarget(target, conversationID)
    }

}
// WDT_IOS1_CHAT_SCREEN_ACTION_BOUNDARIES_20261111_END

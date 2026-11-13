// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
import IM4Domain
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
import IM4Features
import SwiftUI

// WDT_IOS1_CHAT_ROW_FACTORY_20261110_BEGIN
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
extension AppFeatureComposition {
    @MainActor
    static func timelineRowFactory(state: AppState) -> ChatTimelineRowFactory {
        ChatTimelineRowFactory(makeRow: { input, actions in
            AnyView(makeTimelineBubble(
                state: state, row: input.row, conversationID: input.conversationID,
                isGroupConversation: input.isGroupConversation, isBatchSelected: input.isBatchSelected,
                onSelectionTap: actions.onSelectionTap, onLongPress: actions.onLongPress,
                onReadTap: actions.onReadTap, onSenderTap: actions.onSenderTap,
                onContactCardTap: actions.onContactCardTap, onMentionTap: actions.onMentionTap,
                onAttachmentTap: actions.onAttachmentTap
            ))
        })
    }

    @MainActor
    static func makeTimelineBubble(
        state: AppState, row: MessageRowModel, conversationID: String, isGroupConversation: Bool,
        isBatchSelected: Bool = false, onSelectionTap: (() -> Void)? = nil,
        onLongPress: @escaping () -> Void, onReadTap: @escaping () -> Void,
        onSenderTap: @escaping (IMUser) -> Void = { _ in },
        onContactCardTap: @escaping (IMUser) -> Void = { _ in },
        onMentionTap: @escaping (IMUser) -> Void = { _ in },
        onAttachmentTap: @escaping (ChatMessage) -> Void = { _ in }
    ) -> some View {
        ChatBubbleRowObservation(
            row: row, conversationID: conversationID, isGroupConversation: isGroupConversation,
            isBatchSelected: isBatchSelected,
            source: ChatBubbleRowSource(state: state),
            actions: ChatBubbleRowActions(
                onSelectionTap: onSelectionTap, onLongPress: onLongPress, onReadTap: onReadTap,
                onSenderTap: onSenderTap, onContactCardTap: onContactCardTap, onMentionTap: onMentionTap,
                onAttachmentTap: onAttachmentTap,
                onCurrentUserTap: { onSenderTap(state.currentUser) },
                onResend: { state.resend(messageID: row.message.id, in: conversationID) },
                onReviewInvite: { state.reviewGroupInviteApproval($0, approve: $1) },
                onCopy: { state.copyUserID($0) },
                onRedial: { state.redialRTCCallRecord($0, viewerIsCaller: row.message.isOutgoing, conversationID: conversationID) }
            )
        )
    }
}

private struct ChatBubbleRowObservation: View {
    let row: MessageRowModel
    let conversationID: String
    let isGroupConversation: Bool
    let isBatchSelected: Bool
    let source: ChatBubbleRowSource
    let actions: ChatBubbleRowActions

    @Environment(\.enterpriseDisplayName) private var enterpriseDisplayName
    @Environment(\.currentUserDisplay) private var currentUserDisplay
    @Environment(\.tenantShowsGroupMemberCount) private var showsGroupCount
    @Environment(\.chatShowsMessageProcessingNotices) private var showsNotices
    @Environment(\.chatConversationParticipants) private var conversationParticipants
    @Environment(\.chatReadReceiptsEnabled) private var observedReadReceiptsEnabled

    var body: some View {
        ChatBubbleSessionObservation(store: source.tenantInteraction, sessionSource: source.sessionSource,
                                     initialIdentity: source.currentSession) { binding in
            groupObservedContent(binding: binding)
                .environment(\.chatBubbleSessionBinding, binding)
        }
    }

    @ViewBuilder private func groupObservedContent(binding: ChatBubbleSessionBinding) -> some View {
        if isGroupConversation {
            let selectors = source.groupSelectors(conversationID: conversationID)
            if selectors.isEmpty { receiptObservedContent(binding: binding) }
            else {
                GroupSnapshotView(store: source.contacts, selectors: selectors) {
                    receiptObservedContent(binding: binding)
                }
            }
        } else { receiptObservedContent(binding: binding) }
    }

    @ViewBuilder private func receiptObservedContent(binding: ChatBubbleSessionBinding) -> some View {
        let message = row.message
        if isGroupConversation, message.canViewReadDetails,
           message.status == .read || (message.status == .sent && !message.readBy.isEmpty) {
            let store = source.receiptAuthority
            PublisherSnapshotView(initialValue: store[conversationID], updates: store.updates(for: conversationID)) { _ in
                bubble(binding: binding)
            }
        } else { bubble(binding: binding) }
    }

    private func bubble(binding: ChatBubbleSessionBinding) -> some View {
        var origin = source.actionIdentity
        origin.bindingGeneration = binding.generation
        let presentation = source.presentation(
            row: row, conversationID: conversationID, isGroupConversation: isGroupConversation,
            inputs: ChatBubbleDisplayInputs(
                enterpriseDisplayName: enterpriseDisplayName, currentUserDisplay: currentUserDisplay,
                showsGroupCount: showsGroupCount, showsNotices: showsNotices,
                conversationParticipants: conversationParticipants, observedReadReceiptsEnabled: observedReadReceiptsEnabled
            ),
            actionIdentity: origin
        )
        return MessageBubble(
            rowModel: row, conversationID: conversationID, isGroupConversation: isGroupConversation,
            isBatchSelected: isBatchSelected, presentation: presentation,
            actions: actions.guarded(by: { source.isCurrent(origin, binding: binding) }),
            inviteProcessing: row.message.groupInviteApproval.map { source.inviteProcessing(requestID: $0.requestID) }
        )
    }
}

private struct ChatBubbleDisplayInputs {
    let enterpriseDisplayName: String?
    let currentUserDisplay: IMUser?
    let showsGroupCount: Bool?
    let showsNotices: Bool?
    let conversationParticipants: [IMUser]?
    let observedReadReceiptsEnabled: Bool?
}

@MainActor
private struct ChatBubbleRowSource {
    private let state: AppState

    init(state: AppState) { self.state = state }

    var tenantInteraction: TenantInteractionPresentationStore { state.tenantInteractionStore }
    var sessionSource: ChatBubbleSessionIdentitySource { state.chatBubbleSessionIdentitySource }
    var currentSession: ChatBubbleSessionIdentity { state.chatBubbleSessionIdentity }
    var contacts: ContactStore { state.contactStore }
    var receiptAuthority: ReadReceiptDetailAuthorityStore { state.readReceiptAuthorityStore }

    func groupSelectors(conversationID: String) -> [ContactStore.GroupSelector] {
        state.groupObservationSelectors(conversationID: conversationID)
    }

    var actionIdentity: ChatBubbleActionIdentity {
        let session = currentSession
        return ChatBubbleActionIdentity(
            scope: session.scope, sessionGeneration: session.sessionGeneration,
            sessionEpoch: session.sessionEpoch, authoritySessionID: session.authoritySessionID,
            policyGeneration: state.interactionPolicyGeneration
        )
    }

    // A retained row action can never dispatch against a subsequently bound account/session.
    func isCurrent(_ origin: ChatBubbleActionIdentity, binding: ChatBubbleSessionBinding) -> Bool {
        let current = actionIdentity
        return origin.bindingGeneration == binding.generation
            && origin.scope == current.scope
            && origin.sessionGeneration == current.sessionGeneration
            && origin.sessionEpoch == current.sessionEpoch
            && origin.authoritySessionID == current.authoritySessionID
    }

    func inviteProcessing(requestID: String) -> ChatBubbleInviteProcessing {
        ChatBubbleInviteProcessing(
            initialValue: state.groupInviteApprovalProcessingIDs.contains(requestID),
            updates: state.contactStore.groupInviteApprovalProcessingUpdates(requestID: requestID)
        )
    }

    func presentation(row: MessageRowModel, conversationID: String, isGroupConversation: Bool,
                      inputs: ChatBubbleDisplayInputs, actionIdentity: ChatBubbleActionIdentity) -> MessageBubblePresentation {
        ChatBubblePresentationProjection(
            state: state, message: row.message, conversationID: conversationID, isGroupConversation: isGroupConversation,
            resolvedSenderUser: row.senderUser, displaySenderNameOverride: row.displaySenderName, inputs: inputs
        ).presentation(actionIdentity: actionIdentity)
    }
}

@MainActor
private struct ChatBubblePresentationProjection {
    let state: AppState
    let message: ChatMessage
    let conversationID: String
    let isGroupConversation: Bool
    let resolvedSenderUser: IMUser?
    let displaySenderNameOverride: String
    let inputs: ChatBubbleDisplayInputs

    func presentation(actionIdentity: ChatBubbleActionIdentity) -> MessageBubblePresentation {
        MessageBubblePresentation(
            currentUser: renderedCurrentUser, isMembershipSystemEvent: isGroupMembershipSystemEvent(message.systemEventType ?? ""),
            isAuthoredByCurrentUser: isAuthoredByCurrentUser, displaySenderName: displaySenderName, senderGroupRole: senderGroupRole,
            senderUser: senderUser, contactCardUser: contactCardUser, mentionTargets: mentionTargets,
            showsNotices: inputs.showsNotices ?? state.shouldShowMessageProcessingNotices,
            readReceiptsEnabled: readReceiptsEnabled, deliveryText: deliveryText, actionIdentity: actionIdentity
        )
    }

    private var renderedCurrentUser: IMUser { inputs.currentUserDisplay ?? state.currentUser }

    private var isSystemMessage: Bool {
        message.kind == .system
    }

    private var isBubbleOutgoing: Bool {
        isSystemMessage ? false : message.isOutgoing
    }

    private var isAuthoredByCurrentUser: Bool {
        guard !isSystemMessage else { return false }
        return state.isCurrentMessageSender(message.senderId)
    }

    private var displaySenderName: String {
        if !displaySenderNameOverride.isEmpty {
            return displaySenderNameOverride
        }
        guard !isSystemMessage else { return "系统" }
        if let user = resolvedSenderUser {
            if user.isCancelledUser {
                return cancelledUserDisplayName
            }
            let name = state.remarkPreferredDisplayName(for: user, fallback: message.senderId)
            if !name.isEmpty {
                return name
            }
        }
        if isCancelledUserAvatarURL(message.senderAvatarURL) {
            return cancelledUserDisplayName
        }
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let remarkName = state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [storedName],
            fallback: message.senderId.isEmpty ? "未知用户" : message.senderId
        )
        if !remarkName.isEmpty, remarkName != message.senderId {
            return remarkName
        }
        if !storedName.isEmpty, !isIdentifierLikeSenderName(storedName, senderID: message.senderId) {
            return storedName
        }
        return storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
    }

    private var senderGroupRole: ChatSenderGroupRole? {
        guard !isSystemMessage,
              isGroupConversation,
              let group = state.group(id: conversationID) ?? state.group(forConversationID: conversationID) else { return nil }
        let user = isBubbleOutgoing ? renderedCurrentUser : senderUser // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        guard let user else { return nil }
        if state.isGroupOwner(user, in: group) {
            return .owner
        }
        if ChatSenderGroupRole.contains(group.admins, user: user) {
            return .admin
        }
        return nil
    }

    private var displayMessageText: String { chatBubbleDisplayText(for: message) }

    private var senderUser: IMUser? {
        if let resolvedSenderUser {
            return resolvedSenderUser
        }
        return MessageSenderResolver.fallbackUser(
            for: message,
            displayName: displaySenderName,
            enterpriseName: (inputs.enterpriseDisplayName ?? state.currentEnterprise.name)
        )
    }

    private var contactCardUser: IMUser? {
        guard message.kind == .contactCard else { return nil }
        let contactName = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let contactID = message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contactID.isEmpty {
            if let user = state.contacts.first(where: { $0.id == contactID || $0.userID == contactID }) {
                return user
            }
            return IMUser(
                id: contactID,
                name: contactName.isEmpty ? contactID : contactName,
                title: "",
                department: "",
                phone: "",
                email: "",
                status: "在线",
                enterprise: (inputs.enterpriseDisplayName ?? state.currentEnterprise.name),
                avatarSeed: UInt(bitPattern: contactID.hashValue),
                badges: []
            )
        }
        return nil
    }

    private var mentionTargets: [MentionTextTarget] {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：普通文本无 @ 时跳过联系人/群成员解析，减少消息行滚动渲染主线程开销
        guard !isSystemMessage, !message.mentionExcluded, displayMessageText.contains("@") else { return [] }
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
        let participants = inputs.conversationParticipants ?? state.conversation(id: conversationID).participants // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110
        let groupUsers = state.group(forConversationID: conversationID).map { group in
            group.members + group.admins
        } ?? []
        let users = [renderedCurrentUser] + participants + groupUsers // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        var usersByKey: [String: IMUser] = [:]
        for user in users {
            for key in mentionUserStableKeys(for: user) {
                usersByKey[key] = usersByKey[key] ?? user
            }
        }

        let structuredMentionGroups = Dictionary(grouping: message.mentionedUsers) { mention in
            mentionTargetName(mention.displayText)
        }
        let structuredTargets: [MentionTextTarget] = structuredMentionGroups.compactMap { rawName, mentions in
            guard !rawName.isEmpty, !isIdentifierLikeSenderName(rawName, senderID: "") else { return nil }
            let uniqueMentions = mentions.reduce(into: [String: MentionIdentity]()) { partial, mention in
                guard !mention.id.isEmpty else { return }
                partial[mention.id] = partial[mention.id] ?? mention
            }
            let user = uniqueMentions.count == 1
                ? uniqueMentions.values.first.flatMap { resolveMentionUser($0, usersByKey: usersByKey) }
                : nil
            return MentionTextTarget(name: rawName, user: user)
        }
        let sortedTargets = structuredTargets
        .sorted { (lhs: MentionTextTarget, rhs: MentionTextTarget) in
            if lhs.name.count == rhs.name.count {
                return lhs.name < rhs.name
            }
            return lhs.name.count > rhs.name.count
        }
        guard message.mentionAll else { return sortedTargets }
        return [MentionTextTarget(name: "所有人", user: nil, isAll: true)] + sortedTargets
    }

    private func resolveMentionUser(_ mention: MentionIdentity, usersByKey: [String: IMUser]) -> IMUser? {
        for key in [mention.imUID, mention.userID, mention.username]
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }) {
            if let user = usersByKey[key] {
                return user
            }
        }
        guard !mention.id.isEmpty else { return nil }
        let displayName = mentionTargetName(mention.displayText)
        return IMUser(
            id: mention.imUID.isEmpty ? mention.id : mention.imUID,
            userID: mention.userID.isEmpty ? mention.id : mention.userID,
            username: mention.username,
            name: displayName.isEmpty ? mention.id : displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: (inputs.enterpriseDisplayName ?? state.currentEnterprise.name),
            avatarSeed: UInt(bitPattern: mention.id.hashValue),
            badges: []
        )
    }

    private var readReceiptsEnabled: Bool {
        inputs.observedReadReceiptsEnabled ?? state.fileUploadConfig.readReceiptsEnabled
    }

    private var deliveryText: String {
        guard readReceiptsEnabled else { // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110
            switch message.status {
            case .sending:
                return "发送中"
            case .failed:
                return "未送达 · 点按重发"
            case .recalled:
                return "已撤回"
            case .sent:
                return message.deliveryStateKnown ? "已送达" : "已发送"
            case .read:
                return "已读"
            }
        }
        if message.readStateKnown, message.status == .sent {
            return "未读"
        }
        if message.status == .sent, !message.readBy.isEmpty {
            return readStatusText
        }
        switch message.status {
        case .sending:
            return "发送中"
        case .sent:
            return message.deliveryStateKnown ? "已送达" : "已发送"
        case .read:
            return readStatusText
        case .failed:
            return "未送达 · 点按重发"
        case .recalled:
            return "已撤回"
        }
    }

    private var readStatusText: String {
        // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023
        guard state.canViewMessageReadDetails(message, in: state.conversation(id: conversationID)) else { return "已读" }
        let isGroupConversation = state.conversation(id: conversationID).kind == .group
        if isGroupConversation && !(inputs.showsGroupCount ?? state.shouldShowGroupMemberCount) { // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
            return "已读"
        }
        if let readCount = message.readCount {
            return readCount > 0 ? "已读 \(readCount)" : "已读"
        }
        return "已读"
    }
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
// WDT_IOS1_CHAT_ROW_FACTORY_20261110_END

// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_BEGIN
#if DEBUG
@MainActor
enum ChatTimelineRenderDiagnostics {
    static var enabled = false
    static var timelineBodies = 0
    static var bubbleBodies = 0
    static var rowResolutions = 0
    static var scopedBubbleBody: ((String, ChatMessage) -> Void)?
    // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_BEGIN
    static var batchForwardBubble: ((MessageBubble) -> Void)?
    static var batchForwardBar: ((BatchForwardSelectionBar) -> Void)?
    // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110_END
    static var composerBody: ((ChatComposer) -> Void)?
    static var conversationListBody: ((ConversationListView) -> Void)?
    static var chatBody: ((ChatView) -> Void)? // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110
    static func recordTimelineBody() { if enabled { timelineBodies += 1 } }
    static func recordBubbleBody(conversationID: String, message: ChatMessage) {
        if enabled { bubbleBodies += 1; scopedBubbleBody?(conversationID, message) }
    }
    static func recordRowResolution() { if enabled { rowResolutions += 1 } }
    static func reset() {
        timelineBodies = 0; bubbleBodies = 0; rowResolutions = 0
        batchForwardBubble = nil; batchForwardBar = nil // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110
        enabled = false; composerBody = nil; chatBody = nil; conversationListBody = nil; scopedBubbleBody = nil // WDT_IOS1_COMPOSER_PROGRAMMATIC_SELECTION_20261110
    }
}
#endif
// WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110_END

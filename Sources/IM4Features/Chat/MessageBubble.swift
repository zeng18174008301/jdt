import IM4Domain
import IM4DesignSystem
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
public enum ChatSenderGroupRole: Equatable {
    case owner
    case admin

    public var title: String {
        switch self {
        case .owner: "群主"
        case .admin: "管理员"
        }
    }

    public var symbol: String {
        switch self {
        case .owner: "crown.fill"
        case .admin: "checkmark.shield.fill"
        }
    }

    public var color: Color {
        switch self {
        case .owner: IMColor.warning
        case .admin: IMColor.brand
        }
    }
}

private struct ChatSenderRoleIcon: View {
    let role: ChatSenderGroupRole

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: role.symbol)
                .font(.caption2.weight(.black))
            Text(role.title)
                .font(.caption2.weight(.black))
                .lineLimit(1)
        }
        .foregroundStyle(role.color)
        .padding(.horizontal, 5)
        .frame(minHeight: 17)
        .background(Capsule().fill(role.color.opacity(0.13)))
        .overlay(Capsule().stroke(role.color.opacity(0.22), lineWidth: 0.8))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(role.title)
    }
}


private func groupRoleUser(_ roleUser: IMUser, matches targetUser: IMUser) -> Bool {
    let targetKeys = [targetUser.id, targetUser.userID, targetUser.username]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !targetKeys.isEmpty else { return false }
    let roleKeys = [roleUser.id, roleUser.userID, roleUser.username]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return roleKeys.contains { targetKeys.contains($0) }
}

extension ChatSenderGroupRole {
    static public func contains(_ users: [IMUser], user: IMUser) -> Bool {
        users.contains { groupRoleUser($0, matches: user) }
    }
}

// An immutable render input. No Store, AppState, service locator or action is retained here.
public struct ChatBubbleActionIdentity: Equatable {
    public let scope: [String?]
    public let sessionGeneration: UInt64
    public let sessionEpoch: String
    public let authoritySessionID: String
    public let policyGeneration: UUID
    public var bindingGeneration: UUID? = nil

    public init(scope: [String?],
        sessionGeneration: UInt64,
        sessionEpoch: String,
        authoritySessionID: String,
        policyGeneration: UUID,
        bindingGeneration: UUID? = nil) {
        self.scope = scope
        self.sessionGeneration = sessionGeneration
        self.sessionEpoch = sessionEpoch
        self.authoritySessionID = authoritySessionID
        self.policyGeneration = policyGeneration
        self.bindingGeneration = bindingGeneration
    }
}

public struct MessageBubblePresentation: Equatable {
    public let currentUser: IMUser
    public let isMembershipSystemEvent: Bool
    public let isAuthoredByCurrentUser: Bool
    public let displaySenderName: String
    public let senderGroupRole: ChatSenderGroupRole?
    public let senderUser: IMUser?
    public let contactCardUser: IMUser?
    public let mentionTargets: [MentionTextTarget]
    public let showsNotices: Bool
    public let readReceiptsEnabled: Bool
    public let deliveryText: String
    public let actionIdentity: ChatBubbleActionIdentity

    public init(currentUser: IMUser,
        isMembershipSystemEvent: Bool,
        isAuthoredByCurrentUser: Bool,
        displaySenderName: String,
        senderGroupRole: ChatSenderGroupRole? = nil,
        senderUser: IMUser? = nil,
        contactCardUser: IMUser? = nil,
        mentionTargets: [MentionTextTarget],
        showsNotices: Bool,
        readReceiptsEnabled: Bool,
        deliveryText: String,
        actionIdentity: ChatBubbleActionIdentity) {
        self.currentUser = currentUser
        self.isMembershipSystemEvent = isMembershipSystemEvent
        self.isAuthoredByCurrentUser = isAuthoredByCurrentUser
        self.displaySenderName = displaySenderName
        self.senderGroupRole = senderGroupRole
        self.senderUser = senderUser
        self.contactCardUser = contactCardUser
        self.mentionTargets = mentionTargets
        self.showsNotices = showsNotices
        self.readReceiptsEnabled = readReceiptsEnabled
        self.deliveryText = deliveryText
        self.actionIdentity = actionIdentity
    }
}

public struct MessageBubbleContent<SpecialContent: View, ReplyContent: View>: View, Equatable {
    let message: ChatMessage
    let conversationID: String
    let showsSenderHeader: Bool
    var isGroupConversation = false
    var isBatchSelected = false
    var onSelectionTap: (() -> Void)? = nil
    var onLongPress: () -> Void
    var onReadTap: () -> Void
    var onSenderTap: (IMUser) -> Void
    var onContactCardTap: (IMUser) -> Void
    var onMentionTap: (IMUser) -> Void
    var onAttachmentTap: (ChatMessage) -> Void
    var onCurrentUserTap: () -> Void
    var onResend: () -> Void
    let rowModel: MessageRowModel?
    let presentation: MessageBubblePresentation
    let hasSpecialContent: Bool
    @ViewBuilder var specialContent: SpecialContent
    @ViewBuilder var replyContent: ReplyContent
    @Environment(\.chatCertificationRendering) private var certificationSource

#if DEBUG
    private var bodyEvaluationObserver: ((String, ChatMessage) -> Void)?
    public func observingBodyEvaluation(_ observer: @escaping (String, ChatMessage) -> Void) -> Self {
        var value = self; value.bodyEvaluationObserver = observer; return value
    }
#endif

    private var renderedCurrentUser: IMUser { presentation.currentUser }
    private var isAuthoredByCurrentUser: Bool { presentation.isAuthoredByCurrentUser }
    private var displaySenderName: String { presentation.displaySenderName }
    private var senderGroupRole: ChatSenderGroupRole? { presentation.senderGroupRole }
    private var contactCardUser: IMUser? { presentation.contactCardUser }
    private var mentionTargets: [MentionTextTarget] { presentation.mentionTargets }
    private var readReceiptsEnabled: Bool { presentation.readReceiptsEnabled }
    private var deliveryText: String { presentation.deliveryText }

    public var body: some View {
#if DEBUG
        // WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_BEGIN
        let _ = bodyEvaluationObserver?(conversationID, message)
        // WDT_IOS1_CHAT_ACTUAL_ASSEMBLY_20261110_END
#endif
        messageContent
    }

    private var isSystemMessage: Bool {
        message.kind == .system
    }

    private var isRTCCallRecordCard: Bool {
        message.rtcCallRecord != nil
    }

    private var isBubbleOutgoing: Bool {
        isSystemMessage ? false : message.isOutgoing
    }

    private var displayMessageText: String {
        chatBubbleDisplayText(for: message)
    }

    private var isGroupEventSystemMessage: Bool {
        message.kind == .system
            && (message.systemDisplayStyle == "group_event_notice"
                || message.systemColorToken == "im.system.group_event"
                || presentation.isMembershipSystemEvent
                || displayMessageText.contains("加入群「")
                || displayMessageText.contains("移出群「")
                || displayMessageText.contains("退出群「")
                || displayMessageText.contains("离开群「"))
    }

    private var shouldShowReactionMeta: Bool {
        !message.reactions.isEmpty && !isSystemMessage && !isGroupEventSystemMessage
    }

    private var systemEventTextColor: Color {
        Color(im4HexString: message.systemTextColorHex ?? "") ?? Color(im4Hex: 0x2563EB)
    }

    private var systemEventBackgroundColor: Color {
        Color(im4HexString: message.systemBackgroundColorHex ?? "") ?? Color(im4Hex: 0xEFF6FF)
    }

    private var systemEventAccentColor: Color {
        Color(im4HexString: message.systemAccentColorHex ?? "") ?? Color(im4Hex: 0x3B82F6)
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.isDeletedLocally {
            Text("原消息已删除")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.72)))
                .frame(maxWidth: .infinity)
        } else if message.status == .recalled {
            Text(message.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IMColor.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.72)))
                .frame(maxWidth: .infinity)
        } else if isGroupEventSystemMessage {
            bubbleContent
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(alignment: isBubbleOutgoing ? .trailing : .leading, spacing: 6) {
                if showsSenderHeader {
                    senderHeader
                }
                HStack {
                    if isBubbleOutgoing {
                        Spacer(minLength: 54)
                    }
                    bubbleContent
                    if !isBubbleOutgoing {
                        Spacer(minLength: 54)
                    }
                }
                bottomMeta
            }
            .frame(maxWidth: .infinity, alignment: isBubbleOutgoing ? .trailing : .leading)
        }
    }

    private var outgoingSenderDisplayName: String {
        isGroupConversation ? displaySenderName : renderedCurrentUser.displayName
    }

    private var senderHeader: some View {
        HStack(spacing: 8) {
            if isBubbleOutgoing {
                Button {
                    onCurrentUserTap()
                } label: {
                    senderNameWithRole(
                        outgoingSenderDisplayName,
                        exactUID: renderedCurrentUser.id, // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
                        role: senderGroupRole,
                        color: IMColor.muted
                    )
                }
                .buttonStyle(.plain)
                Button {
                    onCurrentUserTap()
                } label: {
                    ChatAvatarView(name: outgoingSenderDisplayName, seed: renderedCurrentUser.avatarSeed, size: 34, imageURL: renderedCurrentUser.displayAvatarURL, avatarVersion: renderedCurrentUser.avatarVersion, avatarUpdatedAt: renderedCurrentUser.avatarUpdatedAt, certificationReference: certificationSource?.reference(forExactUID: renderedCurrentUser.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110 // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
                }
                .buttonStyle(.plain)
            } else {
                if let senderUser {
                    Button {
                        onSenderTap(senderUser)
                    } label: {
                        ChatAvatarView(name: displaySenderName, seed: senderUser.avatarSeed, size: 34, imageURL: senderUser.displayAvatarURL, avatarVersion: senderUser.avatarVersion, avatarUpdatedAt: senderUser.avatarUpdatedAt, certificationReference: certificationSource?.reference(forExactUID: message.senderId)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                    }
                    .buttonStyle(.plain)
                } else {
                    if isSystemMessage {
                        SystemNoticeAvatarContent(image: Image("SystemNoticeLogo", bundle: .main), size: 34)
                    } else {
                        ChatAvatarView(name: displaySenderName, seed: 0x7C6BFF, size: 34, certificationReference: certificationSource?.reference(forExactUID: message.senderId)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                    }
                }
                if let senderUser {
                    Button {
                        onSenderTap(senderUser)
                    } label: {
                        senderNameWithRole(
                            displaySenderName,
                            exactUID: message.senderId,
                            role: senderGroupRole,
                            color: IMColor.peerName
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    senderNameWithRole(
                        displaySenderName,
                        exactUID: message.senderId,
                        role: senderGroupRole,
                        color: IMColor.muted
                    )
                }
            }
        }
        .frame(maxWidth: 286, alignment: isBubbleOutgoing ? .trailing : .leading)
    }

    private func senderNameWithRole(
        _ name: String,
        exactUID: String,
        role: ChatSenderGroupRole?,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            ChatCertificationPillView(
                exactUID: exactUID,
                compact: true
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            if let role {
                ChatSenderRoleIcon(role: role)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
        .certificationAccessibilityLabel(
            name,
            reference: certificationSource?.reference(forExactUID: exactUID),
            trailing: role?.title
        ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
    }

    private var senderUser: IMUser? { presentation.senderUser }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_BEGIN
            if visibleReplyQuote(for: message) != nil {
                replyContent
            }
            // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110_END
            if hasSpecialContent {
                specialContent
            } else if isGroupEventSystemMessage {
                Text(displayMessageText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(systemEventTextColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if message.kind == .system, let systemLinkedUser {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Button {
                        onSenderTap(systemLinkedUser)
                    } label: {
                        Text(systemLinkedUser.name)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(IMColor.brand)
                    }
                    .buttonStyle(.plain)
                    Text(systemMessageRemainder(for: systemLinkedUser))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IMColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                MentionStyledMessageText(
                    text: displayMessageText,
                    targets: mentionTargets,
                    outgoing: isBubbleOutgoing,
                    onMentionTap: onMentionTap
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            if message.isEdited, !isGroupEventSystemMessage, !message.isStickerMessage, presentation.showsNotices { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
                MessageEditedBadge(outgoing: isBubbleOutgoing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AttachmentGIFPresentation.usesBorderlessContainer(message) || isRTCCallRecordCard ? 0 : 14)
        .padding(.vertical, AttachmentGIFPresentation.usesBorderlessContainer(message) || isRTCCallRecordCard ? 0 : 11)
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(AttachmentGIFPresentation.usesBorderlessContainer(message) || isRTCCallRecordCard ? LinearGradient(colors: [.clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing) : bubbleBackground)
        )
        .overlay {
            if isBatchSelected {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(IMColor.brand, lineWidth: 2)
            } else if isGroupEventSystemMessage {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(systemEventAccentColor.opacity(0.28), lineWidth: 1)
            } else if message.isPinned, message.isStickerMessage || !AttachmentGIFPresentation.usesBorderlessContainer(message) {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(IMColor.warning.opacity(0.8), lineWidth: 1.2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if message.isPinned, !isGroupEventSystemMessage {
                PinnedMessageIconBadge(outgoing: isBubbleOutgoing)
                    .padding(.top, -7)
                    .padding(.trailing, -7)
            }
        }
        .frame(maxWidth: AttachmentGIFPresentation.usesBorderlessContainer(message) ? 228 : (isRTCCallRecordCard ? 304 : (isGroupEventSystemMessage ? 318 : 286)), alignment: isGroupEventSystemMessage ? .center : (isBubbleOutgoing ? .trailing : .leading))
        .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .onTapGesture {
            if let onSelectionTap {
                onSelectionTap()
                return
            }
            if message.kind == .file || message.kind == .image || message.kind == .video {
                onAttachmentTap(message)
                return
            }
            guard message.kind == .contactCard, let contactCardUser else { return }
            onContactCardTap(contactCardUser)
        }
        .onLongPressGesture {
            guard !message.isRTCCallRecordMessage else { return }
            onLongPress()
        }
    }

    private var systemLinkedUser: IMUser? {
        guard message.kind == .system else { return nil }
        guard !isGroupEventSystemMessage else { return nil }
        guard let senderUser, senderUser.displayName != "系统", displayMessageText.hasPrefix(senderUser.displayName) else { return nil }
        return senderUser
    }

    private func systemMessageRemainder(for user: IMUser) -> String {
        let text = displayMessageText
        guard text.hasPrefix(user.name) else { return text }
        let remainder = text.dropFirst(user.name.count)
        return remainder.isEmpty ? "" : String(remainder)
    }

    private var bubbleBackground: LinearGradient {
        if isBubbleOutgoing {
            return LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if isGroupEventSystemMessage {
            return LinearGradient(colors: [systemEventBackgroundColor, systemEventBackgroundColor.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [.white, .white.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var bottomMeta: some View {
        VStack(alignment: isBubbleOutgoing ? .trailing : .leading, spacing: 5) {
            MessageMetaTags(message: message)
            if shouldShowReactionMeta {
                reactionsRow
            }
            if isAuthoredByCurrentUser {
                deliveryStatusButton
            }
        }
        .frame(maxWidth: 286, alignment: isBubbleOutgoing ? .trailing : .leading)
    }

    private var reactionsRow: some View {
        // JHT_MOD_BEGIN CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改开始：reaction 渲染按行号访问切片，避免每次气泡重绘构造二维数组
        VStack(alignment: isBubbleOutgoing ? .trailing : .leading, spacing: 5) {
            ForEach(reactionRowIndices, id: \.self) { rowIndex in
                reactionRow(rowIndex)
            }
        }
        .frame(maxWidth: 286, alignment: isBubbleOutgoing ? .trailing : .leading)
        // JHT_MOD_END CHAT_PAGE_SEND_KEYBOARD_SCROLL_PERF_20260912 - 修改结束
    }

    private var reactionRowIndices: Range<Int> {
        0..<((message.reactions.count + 4) / 5)
    }

    private func reactionRow(_ rowIndex: Int) -> some View {
        let reactions = message.reactions
        let start = rowIndex * 5
        let end = min(start + 5, reactions.count)
        return HStack(spacing: 5) {
            ForEach(start..<end, id: \.self) { index in
                reactionPill(reactions[index])
            }
        }
    }

    private func reactionPill(_ reaction: Reaction) -> some View {
        Text("\(reaction.emoji) \(reaction.count)")
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(reaction.reactedByMe ? IMColor.brand.opacity(0.15) : .white.opacity(0.78)))
    }

    private var deliveryStatusButton: some View {
        Button {
            if message.status == .failed {
                onResend()
            } else {
                onReadTap()
            }
        } label: {
            HStack(spacing: 4) {
                if message.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                } else if deliveryShowsReadAffordance {
                    Image(systemName: deliveryText.hasPrefix("已读") ? "checkmark" : "circle")
                        .font(.system(size: 10, weight: .heavy))
                }
                Text(deliveryText)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(deliveryStatusColor)
            .padding(.horizontal, deliveryShowsReadAffordance ? 7 : 0)
            .padding(.vertical, deliveryShowsReadAffordance ? 4 : 2)
            .background {
                if deliveryShowsReadAffordance {
                    Capsule().fill(deliveryStatusColor.opacity(0.10))
                }
            }
            .overlay {
                if deliveryShowsReadAffordance {
                    Capsule().stroke(deliveryStatusColor.opacity(0.18), lineWidth: 0.7)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var deliveryShowsReadAffordance: Bool {
        guard message.status != .failed,
              message.status != .sending,
              message.status != .recalled,
              readReceiptsEnabled else { // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_LOCAL_OBSERVATION_20261110
            return false
        }
        return deliveryText == "未读" || deliveryText.hasPrefix("已读")
    }

    private var deliveryStatusColor: Color {
        if message.status == .failed {
            return IMColor.danger
        }
        guard deliveryShowsReadAffordance else {
            return IMColor.muted
        }
        if deliveryText.hasPrefix("已读") {
            return IMColor.success
        }
        return Color(im4Hex: 0x7A8497)
    }

    nonisolated static public func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.presentation == rhs.presentation,
              lhs.conversationID == rhs.conversationID,
              lhs.isGroupConversation == rhs.isGroupConversation,
              lhs.isBatchSelected == rhs.isBatchSelected,
              lhs.showsSenderHeader == rhs.showsSenderHeader,
              lhs.hasSpecialContent == rhs.hasSpecialContent,
              (lhs.onSelectionTap == nil) == (rhs.onSelectionTap == nil) else { return false }
        if let left = lhs.rowModel, let right = rhs.rowModel { return left == right }
        return lhs.rowModel == nil && rhs.rowModel == nil && lhs.message == rhs.message
    }

    public init(message: ChatMessage,
        conversationID: String,
        showsSenderHeader: Bool,
        isGroupConversation: Bool = false,
        isBatchSelected: Bool = false,
        onSelectionTap: (() -> Void)? = nil,
        onLongPress: @escaping () -> Void,
        onReadTap: @escaping () -> Void,
        onSenderTap: @escaping (IMUser) -> Void,
        onContactCardTap: @escaping (IMUser) -> Void,
        onMentionTap: @escaping (IMUser) -> Void,
        onAttachmentTap: @escaping (ChatMessage) -> Void,
        onCurrentUserTap: @escaping () -> Void,
        onResend: @escaping () -> Void,
        rowModel: MessageRowModel? = nil,
        presentation: MessageBubblePresentation,
        hasSpecialContent: Bool,
        @ViewBuilder specialContent: () -> SpecialContent,
        @ViewBuilder replyContent: () -> ReplyContent) {
        self.message = message
        self.conversationID = conversationID
        self.showsSenderHeader = showsSenderHeader
        self.isGroupConversation = isGroupConversation
        self.isBatchSelected = isBatchSelected
        self.onSelectionTap = onSelectionTap
        self.onLongPress = onLongPress
        self.onReadTap = onReadTap
        self.onSenderTap = onSenderTap
        self.onContactCardTap = onContactCardTap
        self.onMentionTap = onMentionTap
        self.onAttachmentTap = onAttachmentTap
        self.onCurrentUserTap = onCurrentUserTap
        self.onResend = onResend
        self.rowModel = rowModel
        self.presentation = presentation
        self.hasSpecialContent = hasSpecialContent
        self.specialContent = specialContent()
        self.replyContent = replyContent()
    }
}
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END

// WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END

public func chatBubbleDisplayText(for message: ChatMessage) -> String {
        guard message.kind == .system else { return message.text }
        let prefixes = ["系统通知：", "系统通知:", "通知：", "通知:"]
        for prefix in prefixes where message.text.hasPrefix(prefix) {
            return String(message.text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.text
}

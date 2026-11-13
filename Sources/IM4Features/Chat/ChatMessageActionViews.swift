import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

public enum MessageReportCategory: String, CaseIterable, Hashable {
    case illegalTrade = "违规交易"
    case abuse = "辱骂骚扰"
    case spam = "广告引流"
    case sensitivePolitics = "涉政涉敏"

    static public var allowedReasons: [String] {
        allCases.map(\.rawValue)
    }
}

public enum MessageActionMenuKind: Hashable {
    case reply
    case copy
    case pin
    case favorite
    case forward
    case saveAttachment
    case read
    case edit
    case recall
    case delete
    case adminDeleteForAll
    case report

    var accessibilityID: String {
        switch self {
        case .reply: return "reply"
        case .copy: return "copy"
        case .pin: return "pin"
        case .favorite: return "favorite"
        case .forward: return "forward"
        case .saveAttachment: return "save_attachment"
        case .read: return "read"
        case .edit: return "edit"
        case .recall: return "recall"
        case .delete: return "delete"
        case .adminDeleteForAll: return "admin_delete_for_all"
        case .report: return "report"
        }
    }
}

public enum MessageActionMenuTone: Equatable {
    case normal
    case muted
    case danger

    public var color: Color {
        switch self {
        case .normal:
            return IMColor.ink
        case .muted:
            return IMColor.muted
        case .danger:
            return IMColor.danger
        }
    }
}

public struct MessageActionMenuDescriptor: Identifiable, Equatable {
    public let kind: MessageActionMenuKind
    public let symbol: String
    public let title: String
    public let tone: MessageActionMenuTone
    let showsDividerBefore: Bool
    public var disabledReason: String? = nil

    public var id: MessageActionMenuKind { kind }
}

public func messageReportActionIsAvailable(message: ChatMessage, isCurrentUserSender: Bool) -> Bool {
    let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !messageID.isEmpty,
          !messageID.hasPrefix("local_"),
          !isCurrentUserSender,
          message.kind != .system,
          message.status != .sending,
          message.status != .failed,
          message.status != .recalled,
          !message.isDeletedLocally else {
        return false
    }
    return true
}

public func chatMessageActionMenuDescriptors(
    message: ChatMessage,
    canShowReadActions: Bool,
    readActionTitle: String,
    canForward: Bool,
    forwardDisabledReason: String? = nil,
    canSaveAttachment: Bool,
    canFavoriteAsset: Bool,
    canReportMessage: Bool,
    canAdminDeleteForAll: Bool,
    editDisabledReason: String? = nil,
    recallDisabledReason: String?,
    ownDeletionTitle: String?
) -> [MessageActionMenuDescriptor] {
    guard !message.isRTCCallRecordMessage else { return [] }
    var items: [MessageActionMenuDescriptor] = [
        MessageActionMenuDescriptor(kind: .reply, symbol: "arrowshape.turn.up.left", title: "回复", tone: .normal, showsDividerBefore: false),
        MessageActionMenuDescriptor(kind: .pin, symbol: "pin", title: message.isPinned ? "取消置顶" : "置顶", tone: .normal, showsDividerBefore: false)
    ]
    if message.kind == .text {
        items.insert(MessageActionMenuDescriptor(kind: .copy, symbol: "doc.on.doc", title: "拷贝", tone: .normal, showsDividerBefore: false), at: 1)
    }
    if canFavoriteAsset {
        items.append(MessageActionMenuDescriptor(kind: .favorite, symbol: message.isFavorited ? "star.slash" : "star", title: message.isFavorited ? "取消收藏" : "收藏", tone: .normal, showsDividerBefore: false))
    }
    if canForward {
        items.append(MessageActionMenuDescriptor(kind: .forward, symbol: "arrowshape.turn.up.right", title: "转发", tone: .normal, showsDividerBefore: false))
    } else if let forwardDisabledReason,
              !forwardDisabledReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        items.append(
            MessageActionMenuDescriptor(
                kind: .forward,
                symbol: "arrowshape.turn.up.right",
                title: "转发",
                tone: .muted,
                showsDividerBefore: false,
                disabledReason: forwardDisabledReason
            )
        )
    }
    if canSaveAttachment {
        items.append(MessageActionMenuDescriptor(kind: .saveAttachment, symbol: "square.and.arrow.down", title: "保存", tone: .normal, showsDividerBefore: false))
    }
    if canShowReadActions {
        items.append(MessageActionMenuDescriptor(kind: .read, symbol: "checkmark.seal", title: readActionTitle, tone: .normal, showsDividerBefore: true))
    }
    if message.isOutgoing && message.kind == .text {
        items.append(MessageActionMenuDescriptor(
            kind: .edit,
            symbol: "pencil",
            title: "编辑",
            tone: editDisabledReason == nil ? .normal : .muted,
            showsDividerBefore: false,
            disabledReason: editDisabledReason
        ))
    }
    if message.isOutgoing {
        let recallTitle = "撤回"
        items.append(MessageActionMenuDescriptor(
            kind: .recall,
            symbol: "arrow.uturn.backward.circle",
            title: recallTitle,
            tone: recallDisabledReason == nil ? .danger : .muted,
            showsDividerBefore: true,
            disabledReason: recallDisabledReason
        ))
    }
    if let ownDeletionTitle {
        items.append(MessageActionMenuDescriptor(
            kind: .delete,
            symbol: "trash",
            title: ownDeletionTitle,
            tone: .danger,
            showsDividerBefore: true
        ))
    }
    if canAdminDeleteForAll {
        items.append(MessageActionMenuDescriptor(
            kind: .adminDeleteForAll,
            symbol: "trash.slash.fill",
            title: "对全员删除该消息",
            tone: .danger,
            showsDividerBefore: true
        ))
    }
    if canReportMessage {
        items.append(MessageActionMenuDescriptor(
            kind: .report,
            symbol: "exclamationmark.shield.fill",
            title: "举报此消息",
            tone: .danger,
            showsDividerBefore: true
        ))
    }
    return items
}

func messageReportPreviewText(for message: ChatMessage) -> String {
    switch message.kind {
    case .rtcCallRecord:
        return message.rtcCallRecord.map { RTCCallRecordPresentation(record: $0, viewerIsCaller: message.isOutgoing, dialedAtText: "").conversationPreview }
            ?? "[通话记录]"
    case .image:
        return "[图片]"
    case .video:
        return "[视频]"
    case .file:
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[文件]" : "[文件] \(name)"
    case .voice:
        return "[语音]"
    case .contactCard:
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "[名片]" : "[名片] \(name)"
    case .location:
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "[位置]" : "[位置] \(text)"
    case .system:
        return "[系统消息]"
    case .text:
        let text = message.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "[空消息]" : text
    }
}

public struct MessageActionOverlayContent: View {
    let message: ChatMessage
    let conversationID: String
    let preview: AnyView
    let canShowReadActions: Bool
    let readActionTitle: String
    let canForward: Bool
    let forwardDisabledReason: String?
    let canSaveAttachment: Bool
    let canFavoriteAsset: Bool
    let canReportMessage: Bool
    let canAdminDeleteForAll: Bool
    let editDisabledReason: String?
    let recallDisabledReason: String?
    let descriptors: [MessageActionMenuDescriptor]
    let onDismiss: () -> Void
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onRead: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onFavorite: () -> Void
    let onForward: () -> Void
    let onSaveAttachment: () -> Void
    let onReport: () -> Void
    let onDelete: () -> Void
    let onAdminDeleteForAll: () -> Void
    let onRecall: () -> Void

    private let quickReactions = ["👌", "👍", "😂", "❤️", "👎", "🔥", "🥰"]

    private var menuDescriptors: [MessageActionMenuDescriptor] { descriptors }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 9) {
                Spacer(minLength: 80)
                reactionBar
                preview
                actionMenu
                Spacer(minLength: 18)
            }
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
            .padding(.horizontal, 18)
        }
        .colorScheme(.light)
    }

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            Button(action: onMoreReactions) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(IMColor.success.opacity(0.60)))
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(
            Capsule()
                .fill(Color.white)
                .overlay(Capsule().stroke(Color(im4Hex: 0xE7EBF4), lineWidth: 1))
                .shadow(color: Color(im4Hex: 0x29345C).opacity(0.16), radius: 18, y: 10)
        )
        .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
            ReactionTail()
                .offset(x: message.isOutgoing ? -42 : 42, y: 15)
        }
    }

    private var actionMenu: some View {
        VStack(spacing: 0) {
            ForEach(menuDescriptors) { item in
                if item.showsDividerBefore {
                    MessageActionMenuDivider()
                }
                MessageActionMenuRow(
                    symbol: item.symbol,
                    title: item.title,
                    tint: item.tone.color,
                    accessibilityID: "message_action_\(item.kind.accessibilityID)",
                    disabledReason: item.disabledReason,
                    action: action(for: item.kind)
                )
            }
        }
        .frame(width: 268)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color(im4Hex: 0xE7EBF4), lineWidth: 1)
                )
                .shadow(color: Color(im4Hex: 0x29345C).opacity(0.18), radius: 24, y: 14)
        )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func action(for kind: MessageActionMenuKind) -> () -> Void {
        switch kind {
        case .reply:
            return onReply
        case .copy:
            return onCopy
        case .pin:
            return onPin
        case .favorite:
            return onFavorite
        case .forward:
            return onForward
        case .saveAttachment:
            return onSaveAttachment
        case .read:
            return onRead
        case .edit:
            return onEdit
        case .recall:
            return onRecall
        case .delete:
            return onDelete
        case .adminDeleteForAll:
            return onAdminDeleteForAll
        case .report:
            return onReport
        }
    }

    public init(message: ChatMessage,
        conversationID: String,
        preview: AnyView,
        canShowReadActions: Bool,
        readActionTitle: String,
        canForward: Bool,
        forwardDisabledReason: String? = nil,
        canSaveAttachment: Bool,
        canFavoriteAsset: Bool,
        canReportMessage: Bool,
        canAdminDeleteForAll: Bool,
        editDisabledReason: String? = nil,
        recallDisabledReason: String? = nil,
        descriptors: [MessageActionMenuDescriptor],
        onDismiss: @escaping () -> Void,
        onReact: @escaping (String) -> Void,
        onMoreReactions: @escaping () -> Void,
        onReply: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onRead: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onFavorite: @escaping () -> Void,
        onForward: @escaping () -> Void,
        onSaveAttachment: @escaping () -> Void,
        onReport: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onAdminDeleteForAll: @escaping () -> Void,
        onRecall: @escaping () -> Void) {
        self.message = message
        self.conversationID = conversationID
        self.preview = preview
        self.canShowReadActions = canShowReadActions
        self.readActionTitle = readActionTitle
        self.canForward = canForward
        self.forwardDisabledReason = forwardDisabledReason
        self.canSaveAttachment = canSaveAttachment
        self.canFavoriteAsset = canFavoriteAsset
        self.canReportMessage = canReportMessage
        self.canAdminDeleteForAll = canAdminDeleteForAll
        self.editDisabledReason = editDisabledReason
        self.recallDisabledReason = recallDisabledReason
        self.descriptors = descriptors
        self.onDismiss = onDismiss
        self.onReact = onReact
        self.onMoreReactions = onMoreReactions
        self.onReply = onReply
        self.onCopy = onCopy
        self.onRead = onRead
        self.onEdit = onEdit
        self.onPin = onPin
        self.onFavorite = onFavorite
        self.onForward = onForward
        self.onSaveAttachment = onSaveAttachment
        self.onReport = onReport
        self.onDelete = onDelete
        self.onAdminDeleteForAll = onAdminDeleteForAll
        self.onRecall = onRecall
    }
}

private struct ReactionTail: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.white.opacity(0.88))
                .frame(width: 9, height: 9)
            Circle()
                .fill(.white.opacity(0.78))
                .frame(width: 5, height: 5)
        }
    }
}

public struct MessageActionPreviewContent: View {
    let message: ChatMessage
    let conversationID: String
    let displaySenderName: String
    let certification: ChatCertificationRendering.Reference?
    let replyContent: AnyView?
    let richContent: AnyView
    @Environment(\.chatRenderingShowsMessageProcessingNotices) private var showsNotices // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110

    public var body: some View { previewContent() }

    private func previewContent() -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
            senderHeader
            previewBubble
                .padding(.leading, message.isOutgoing ? 0 : 38)
                .padding(.trailing, message.isOutgoing ? 38 : 0)
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var senderHeader: some View {
        HStack(spacing: 8) {
            if message.isOutgoing {
                HStack(spacing: 4) {
                    Text(displaySenderName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    ChatCertificationPillView(
                        exactUID: message.senderId,
                        compact: true
                    )
                }
                ChatAvatarView(name: displaySenderName, seed: message.senderAvatarSeed == 0 ? 0x5D6BFF : message.senderAvatarSeed, size: 30, imageURL: message.senderAvatarURL, avatarVersion: message.senderAvatarVersion, avatarUpdatedAt: message.senderAvatarUpdatedAt, certificationReference: certification) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            } else {
                ChatAvatarView(name: displaySenderName, seed: message.senderAvatarSeed == 0 ? 0x7C6BFF : message.senderAvatarSeed, size: 30, imageURL: message.senderAvatarURL, avatarVersion: message.senderAvatarVersion, avatarUpdatedAt: message.senderAvatarUpdatedAt, certificationReference: certification) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                HStack(spacing: 4) {
                    Text(displaySenderName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                    ChatCertificationPillView(
                        exactUID: message.senderId,
                        compact: true
                    )
                }
            }
        }
        .frame(maxWidth: 324, alignment: message.isOutgoing ? .trailing : .leading)
    }

    private var previewBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let replyContent { replyContent }

            if message.isStickerMessage {
                richContent
            } else if message.kind == .file || message.kind == .image || message.kind == .video {
                richContent
            } else if message.kind == .contactCard {
                richContent
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(message.text)
                        .font(.system(size: 15, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message.time)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.68) : IMColor.muted)
                }
            }
        }
        .foregroundStyle(message.isOutgoing ? .white : IMColor.ink)
        .padding(.horizontal, AttachmentGIFPresentation.usesBorderlessContainer(message) ? 0 : 13)
        .padding(.vertical, AttachmentGIFPresentation.usesBorderlessContainer(message) ? 0 : 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AttachmentGIFPresentation.usesBorderlessContainer(message) ? LinearGradient(colors: [.clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing) : (message.isOutgoing ? LinearGradient(colors: [IMColor.brand, IMColor.violet], startPoint: .topLeading, endPoint: .bottomTrailing) : LinearGradient(colors: [.white, .white.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: Color.black.opacity(AttachmentGIFPresentation.usesBorderlessContainer(message) ? 0 : 0.10), radius: 12, y: 6)
        )
        .frame(maxWidth: AttachmentGIFPresentation.usesBorderlessContainer(message) ? 228 : 286, alignment: message.isOutgoing ? .trailing : .leading)
    }

    public init(message: ChatMessage,
        conversationID: String,
        displaySenderName: String,
        certification: ChatCertificationRendering.Reference? = nil,
        replyContent: AnyView? = nil,
        richContent: AnyView) {
        self.message = message
        self.conversationID = conversationID
        self.displaySenderName = displaySenderName
        self.certification = certification
        self.replyContent = replyContent
        self.richContent = richContent
    }
}

private struct MessageActionMenuRow: View {
    let symbol: String
    let title: String
    var tint: Color = IMColor.ink
    var accessibilityID: String? = nil
    var disabledReason: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(tint)
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .disabled(disabledReason != nil)
        .buttonStyle(.plain)
        .opacity(disabledReason == nil ? 1 : 0.58)
        .accessibilityIdentifier(accessibilityID ?? "")
        .accessibilityLabel(disabledReason ?? title)
        .accessibilityValue(disabledReason == nil ? "" : "不可用")
    }
}

private struct MessageActionMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(im4Hex: 0xE7EBF4))
            .frame(height: 1)
            .padding(.leading, 56)
            .padding(.trailing, 18)
    }
}

public struct UserQuickActionContent: View {
    let displayName: String
    let certification: ChatCertificationRendering.Reference?
    let department: String?
    let user: IMUser
    var showsMentionAction = true
    let onDismiss: () -> Void
    let onMention: () -> Void
    let onDetail: () -> Void

    public var body: some View { quickActionContent }

    private var quickActionContent: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                Capsule()
                    .fill(IMColor.line)
                    .frame(width: 42, height: 5)

                HStack(spacing: 12) {
                    ChatAvatarView(name: displayName, seed: user.avatarSeed, size: 52, imageURL: user.displayAvatarURL, avatarVersion: user.avatarVersion, avatarUpdatedAt: user.avatarUpdatedAt, certificationReference: certification) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.system(size: 19, weight: .black))
                                .foregroundStyle(IMColor.ink)
                                .lineLimit(1)
                            ChatCertificationPillView(
                                exactUID: user.id,
                                compact: true
                            )
                        }
                        if user.isCancelledUser {
                            Text("已注销")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(IMColor.muted)
                        }
                        // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_BEGIN
                            if let department {
                                Label(department, systemImage: "building.2.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(IMColor.muted)
                                    .lineLimit(1)
                            }
                        // WDT_IOS1_REFACTOR_ORGANIZATION_DIRECTORY_OBSERVATION_20261110_END
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(IMColor.muted)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(im4Hex: 0xF0F3FF)))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 10) {
                    UserQuickActionRow(symbol: "person.crop.circle", title: "查看详情", tint: IMColor.ink, action: onDetail)
                    if showsMentionAction {
                        UserQuickActionRow(symbol: "at", title: "@TA", tint: IMColor.brand, action: onMention)
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color(im4Hex: 0xE7EBF4), lineWidth: 1))
                    .shadow(color: Color(im4Hex: 0x29345C).opacity(0.18), radius: 34, y: 18)
            )
            .padding(.horizontal, 28)
            .frame(maxWidth: 430)
        }
        .colorScheme(.light)
    }

    public init(displayName: String,
        certification: ChatCertificationRendering.Reference? = nil,
        department: String? = nil,
        user: IMUser,
        showsMentionAction: Bool = true,
        onDismiss: @escaping () -> Void,
        onMention: @escaping () -> Void,
        onDetail: @escaping () -> Void) {
        self.displayName = displayName
        self.certification = certification
        self.department = department
        self.user = user
        self.showsMentionAction = showsMentionAction
        self.onDismiss = onDismiss
        self.onMention = onMention
        self.onDetail = onDetail
    }
}

private struct UserQuickActionRow: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(IMColor.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(IMColor.muted.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.78)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

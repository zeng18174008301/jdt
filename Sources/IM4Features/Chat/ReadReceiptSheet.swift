import IM4Domain
import IM4DesignSystem
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_BEGIN
import UIKit

// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_BEGIN
public struct ReadReceiptContent: View {
    let input: ChatReceiptInput
    private var renderedCurrentUser: IMUser { input.currentUser }

    let message: ChatMessage
    let conversation: ConversationMessageSnapshot
    let readReceiptsEnabled: Bool

    private var isDirectConversation: Bool {
        conversation.kind == .direct
    }

    private var showAggregateCounts: Bool {
        canViewReceiptDetails && (isDirectConversation || input.showsGroupMemberCount)
    }

    private var peer: IMUser? {
        conversation.participants.first { $0.id != message.senderId } ?? conversation.participants.first
    }

    private var peerDisplayName: String {
        guard let peer else { return "对方" }
        return input.peerDisplayName
    }

    private var directRead: Bool {
        message.status == .read
    }

    private var canViewReceiptDetails: Bool {
        input.canViewDetails
    }

    private var readReceiptCount: Int? {
        guard showAggregateCounts else { return nil }
        return message.readCount
    }

    private var unreadReceiptCount: Int? {
        guard showAggregateCounts else { return nil }
        if let unreadCount = message.unreadCount {
            return unreadCount
        }
        return nil
    }

    private var unreadSectionTitle: String {
        if let unreadReceiptCount, showAggregateCounts {
            return "未读 \(unreadReceiptCount)"
        }
        return "未读明细"
    }

    private var unreadEmptyText: String {
        if let unreadReceiptCount, showAggregateCounts {
            if unreadReceiptCount == 0 {
                return "暂无未读成员"
            }
            return "后端未返回未读成员明细，当前按群成员数和已读数推算仍有 \(unreadReceiptCount) 人未读。"
        }
        return "后端暂未返回未读统计或成员明细，无法确认未读人数。"
    }

    private var directStatusTitle: String {
        if message.isOutgoing {
            return directRead ? "对方已读" : "对方未读"
        }
        return "你已读此消息"
    }

    private var directStatusDetail: String {
        if let receipt = message.readBy.first {
            return "已读时间 \(receipt.time)"
        }
        if message.isOutgoing {
            return directRead ? "已确认送达并读取" : "消息已送达，等待对方查看"
        }
        return "当前设备已完成阅读"
    }

    private var directReceiptExactUID: String {
        message.isOutgoing ? peer?.id ?? "" : renderedCurrentUser.id
    }

    private var directReceiptDisplayName: String {
        message.isOutgoing
            ? peerDisplayName
            : renderedCurrentUser.displayName
    }

    public var body: some View { receiptContent }

    private var receiptContent: some View {
        NavigationStackCompat {
            ZStack {
                AuroraBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetHeader(
                            symbol: "checkmark.seal.fill",
                            title: readReceiptsEnabled ? (canViewReceiptDetails && !isDirectConversation ? "已读列表" : "已读状态") : "已读状态",
                            subtitle: readReceiptsEnabled ? (canViewReceiptDetails && !isDirectConversation ? "查看群成员对这条消息的读取状态。" : "查看这条消息是否已被读取。") : "当前企业未开通",
                            showsCloseButton: true
                        )

                        if !readReceiptsEnabled {
                            readReceiptDisabledCard
                            reactionSection // WDT_RECEIPT_DETAIL_SCOPE_20261023: reactions do not depend on read receipts.
                        } else if !canViewReceiptDetails {
                            // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023_BEGIN
                            if isDirectConversation { anonymousReceiptCard }
                            receiptSection(title: "已读", receipts: [], read: true, emptyText: "未统计明细")
                            reactionSection
                            receiptSection(title: "未读", receipts: [], read: false, emptyText: "未统计明细")
                            // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023_END
                        } else if isDirectConversation {
                            directReceiptCard
                            reactionSection
                        } else {
                            receiptSection(
                                title: readReceiptCount.map { "已读 \($0)" } ?? "已读明细",
                                receipts: input.readBy,
                                read: true,
                                emptyText: "暂无成员已读"
                            )
                            reactionSection
                            receiptSection(title: unreadSectionTitle, receipts: input.unreadBy, read: false, emptyText: unreadEmptyText)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .im4PresentationDragIndicatorCompat(.visible)
    }

    private var readReceiptDisabledCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(IMColor.muted)
                .frame(width: 54, height: 54)
                .background(Circle().fill(IMColor.muted.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                Text("当前企业未开通")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(IMColor.ink)
            }
            Spacer()
        }
        .im4PlainCard(radius: 24)
    }

    private var anonymousReceiptCard: some View {
        HStack(spacing: 14) {
            Image(systemName: directRead ? "checkmark.seal.fill" : "clock.fill")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(directRead ? IMColor.success : IMColor.muted)
                .frame(width: 52, height: 52)
                .background(Circle().fill((directRead ? IMColor.success : IMColor.muted).opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(directRead ? "已读" : (message.readStateKnown ? "未读" : "状态待同步"))
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    StatusPill(title: directRead ? "已读" : (message.readStateKnown ? "未读" : "状态待同步"), color: directRead ? IMColor.success : IMColor.muted)
                }
                Text(directRead ? "对方已读取这条消息" : (message.readStateKnown ? "对方暂未读取这条消息" : "尚未确认对方的读取状态"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
        }
        .im4PlainCard(radius: 24)
    }

    private var directReceiptCard: some View {
        HStack(spacing: 14) {
            ChatAvatarView(
                name: directReceiptDisplayName,
                seed: message.isOutgoing
                    ? (peer?.avatarSeed ?? 0x7C6BFF)
                    : renderedCurrentUser.avatarSeed,
                size: 50,
                badgeColor: directRead ? IMColor.success : IMColor.muted,
                imageURL: message.isOutgoing
                    ? peer?.displayAvatarURL ?? ""
                    : renderedCurrentUser.displayAvatarURL,
                avatarVersion: message.isOutgoing
                    ? peer?.avatarVersion ?? ""
                    : renderedCurrentUser.avatarVersion,
                avatarUpdatedAt: message.isOutgoing
                    ? peer?.avatarUpdatedAt ?? ""
                    : renderedCurrentUser.avatarUpdatedAt,
                certificationReference: input.certifications[directReceiptExactUID]
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(directReceiptDisplayName)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    ChatCertificationPillView(
                        exactUID: directReceiptExactUID,
                        compact: true
                    )
                    StatusPill(title: directRead ? "已读" : "未读", color: directRead ? IMColor.success : IMColor.muted)
                }
                Text(directStatusTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(IMColor.ink)
                Text(directStatusDetail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
        }
        .im4PlainCard(radius: 24)
    }

    private func receiptSection(title: String, receipts: [ChatReadReceiptPresentation], read: Bool, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)
            if receipts.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.68)))
            } else {
                ForEach(receipts) { row in
                    // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_BEGIN
                    ReceiptRow(
                        receipt: row.receipt,
                        displayName: row.displayName,
                        read: read,
                        certification: input.certifications[row.receipt.user.id]
                    )
                    // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_END
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                }
            }
        }
        .im4PlainCard(radius: 24)
    }

    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("回应清单")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(IMColor.ink)
            if input.reactionDetails.isEmpty {
                Text("暂无回应")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.68)))
            } else {
                ForEach(input.reactionDetails) { row in
                    // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_BEGIN
                    ReactionDetailRow(
                        reaction: row.reaction,
                        displayName: row.displayName
                    )
                    // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110_END
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.78)))
                }
            }
        }
        .im4PlainCard(radius: 24)
    }

    public init(input: ChatReceiptInput,
        message: ChatMessage,
        conversation: ConversationMessageSnapshot,
        readReceiptsEnabled: Bool) {
        self.input = input
        self.message = message
        self.conversation = conversation
        self.readReceiptsEnabled = readReceiptsEnabled
    }
}
// WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110_END

private struct ReceiptRow: View {

    let receipt: ReadReceipt
    let displayName: String // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110
    let read: Bool
    let certification: ChatCertificationRendering.Reference?

    var body: some View {
#if DEBUG
        let _ = ChatReceiptRowDiagnostics.render?(ChatReceiptRowRender(
            kind: read ? .read : .unread, recordID: receipt.id, user: receipt.user, displayName: displayName))
#endif
        HStack(spacing: 12) {
            ChatAvatarView(name: displayName, seed: receipt.user.avatarSeed, size: 38, badgeColor: read ? IMColor.success : IMColor.muted, imageURL: receipt.user.avatarURL, avatarVersion: receipt.user.avatarVersion, avatarUpdatedAt: receipt.user.avatarUpdatedAt, certificationReference: certification) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    ChatCertificationPillView(
                        exactUID: receipt.user.id,
                        compact: true
                    )
                }
                Text(read ? "已读时间 \(receipt.time)" : "暂未读取")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            StatusPill(title: read ? "已读" : "未读", color: read ? IMColor.success : IMColor.muted)
        }
    }
}

private struct ReactionDetailRow: View {

    let reaction: ReactionDetail

    let displayName: String // WDT_IOS1_REFACTOR_MESSAGE_SHEET_CONTACT_OBSERVATION_20261110

    var body: some View {
#if DEBUG
        let _ = ChatReceiptRowDiagnostics.render?(ChatReceiptRowRender(
            kind: .reaction, recordID: reaction.id, user: reaction.user, displayName: displayName))
#endif
        HStack(spacing: 12) {
            Text(reaction.emoji)
                .font(.system(size: 22))
                .frame(width: 38, height: 38)
                .background(Circle().fill(IMColor.brand.opacity(0.1)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    ChatCertificationPillView(
                        exactUID: reaction.user.id,
                        compact: true
                    )
                }
                Text("回应时间 \(reaction.time)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IMColor.muted)
            }
            Spacer()
            StatusPill(title: "回应", color: IMColor.brand)
        }
    }
} // WDT_IOS1_SCOPED_CHAT_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

#if DEBUG
// WDT_IOS1_SECONDARY_RECEIPT_ROW_SNAPSHOT_20261111_BEGIN
// Passive observation of the same value passed to the actual row Text/Avatar.
struct ChatReceiptRowRender {
    enum Kind: String { case read, unread, reaction }
    let kind: Kind
    let recordID: String
    let user: IMUser
    let displayName: String
}
@MainActor enum ChatReceiptRowDiagnostics {
    static var render: ((ChatReceiptRowRender) -> Void)?
}
// WDT_IOS1_SECONDARY_RECEIPT_ROW_SNAPSHOT_20261111_END
#endif

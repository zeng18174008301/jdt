// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import UIKit
import IM4Domain
import IM4DesignSystem

public struct ConversationTypeBadge: View {
    let title: String
    let color: Color

    public init(title: String, color: Color) { self.title = title; self.color = color }

    public var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(title == "群" ? IMColor.warning : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(title == "群" ? Color(im4Hex: 0xFFF4D6) : color)
                    .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.4))
            )
            .shadow(color: color.opacity(0.18), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

public struct ConversationInteractiveRowContent<Avatar: View, Certification: View>: View, Equatable {
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：交互行只持有轻量展示字段，避免完整 ConversationMessageSnapshot 参与 SwiftUI diff
    let rowModel: ConversationRowInput
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    let mentionTarget: String
    let unreadMention: ConversationMentionPreview?
    let systemNoticeAvatarURL: String
    var onTap: () -> Void
    var onLongPress: () -> Void

    let avatar: () -> Avatar
    let certification: () -> Certification
    public init(rowModel: ConversationRowInput, mentionTarget: String, unreadMention: ConversationMentionPreview?,
                systemNoticeAvatarURL: String, @ViewBuilder avatar: @escaping () -> Avatar,
                @ViewBuilder certification: @escaping () -> Certification,
                onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        self.rowModel = rowModel; self.mentionTarget = mentionTarget; self.unreadMention = unreadMention
        self.systemNoticeAvatarURL = systemNoticeAvatarURL; self.avatar = avatar; self.certification = certification
        self.onTap = onTap; self.onLongPress = onLongPress
    }

    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：直接比较轻量行模型，避开 ConversationMessageSnapshot.messages 等大字段
        lhs.rowModel == rhs.rowModel
            && lhs.mentionTarget == rhs.mentionTarget
            && lhs.unreadMention == rhs.unreadMention
            && lhs.systemNoticeAvatarURL == rhs.systemNoticeAvatarURL
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    }

    public var body: some View {
        ConversationRow(
            rowModel: rowModel,
            mentionTarget: mentionTarget,
            unreadMention: unreadMention,
            systemNoticeAvatarURL: systemNoticeAvatarURL, avatar: avatar, certification: certification
        )
        // Renew the visual subtree on pin changes without changing the list row ID.
        // Reordering alone must not retain the previous unpinned presentation.
        .id(rowModel.isPinned)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onLongPress()
        }
        .accessibilityIdentifier("conversation_row_\(rowModel.id)")
        .accessibilityLabel(
            [
                "会话 \(rowModel.displayTitle)",
                rowModel.kind == .direct
                    ? rowModel.rowPresentation.directCertificationPresentation?.accessibilityLabel
                    : nil
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

private struct ConversationRow<Avatar: View, Certification: View>: View {
// JHT_MOD_END CONVERSATION_LIST_SCROLL_PERF_END_ROW_PRIVATE_SCOPE - 修改结束：会话行仅在当前文件使用，配合私有展示缓存
    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：实际行视图只依赖轻量展示模型
    let rowModel: ConversationRowInput
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    var mentionTarget: String = ""
    var unreadMention: ConversationMentionPreview?
    var systemNoticeAvatarURL: String = ""
    let avatar: () -> Avatar
    let certification: () -> Certification
    private let listAvatarSize: CGFloat = 56

    private var displayTitle: String {
        rowModel.displayTitle
    }

    private var rowPresentation: ConversationRowAvatarInput {
        rowModel.rowPresentation
    }

    private var unreadBadgeColor: Color {
        rowModel.isMuted ? IMColor.muted.opacity(0.62) : IMColor.danger
    }

    private var reactionUnreadColor: Color {
        rowModel.isMuted ? IMColor.warning.opacity(0.12) : IMColor.warning.opacity(0.18)
    }

    private var reactionUnreadTextColor: Color {
        rowModel.isMuted ? IMColor.warning.opacity(0.72) : IMColor.warning
    }

    private var shouldShowReactionUnreadBadge: Bool {
        rowModel.hasUnreadReaction || rowModel.unreadReactionCount > 0
    }

    private var conversationTag: (title: String, color: Color)? {
        switch rowModel.kind {
        case .group:
            return ("群", IMColor.warning)
        case .system:
            return ("系", IMColor.cyan)
        case .direct:
            return nil
        }
    }

    private var displayTime: String {
        featureConversationListDisplayTime(rawTime: rowModel.time, sortTimestamp: rowModel.sortTimestamp)
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomLeading) {
                avatar()
                if let conversationTag {
                    ConversationTypeBadge(title: conversationTag.title, color: conversationTag.color)
                        .offset(x: -4, y: 4)
                }
            }
            .frame(width: listAvatarSize, height: listAvatarSize)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    // WDT_APP_CONTRACT_20261021_05: the count has its own untruncated layout.
                    if let count = rowModel.groupMemberCount {
                        Text(String(count))
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(IMColor.brand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(IMColor.brand.opacity(0.10)))
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)
                            .accessibilityLabel("群成员 \(count) 人")
                    }
                    if rowModel.kind == .direct {
                        certification()
                    }
                    if rowModel.isPinned {
                        ConversationStatusChip(
                            symbol: "pin.fill",
                            title: "置顶",
                            color: IMColor.warning,
                            fill: Color(im4Hex: 0xFFF1C7)
                        )
                    }
                    if rowModel.isMuted {
                        ConversationStatusChip(
                            symbol: "bell.slash.fill",
                            title: "免扰",
                            color: IMColor.muted,
                            fill: Color(im4Hex: 0xEEF2FA)
                        )
                    }
                }
                summaryText
                    .font(.system(size: 13, weight: unreadMention == nil ? .medium : .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                if !displayTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(displayTime)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                if let unreadText = UnreadBadgeFormatter.text(rowModel.unread) {
                    HStack(spacing: 5) {
                        if shouldShowReactionUnreadBadge {
                            Text("[表情]")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(reactionUnreadTextColor)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(Capsule().fill(reactionUnreadColor))
                        }
                        Text(unreadText)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Capsule().fill(unreadBadgeColor))
                    }
                }
            }
        }
        .padding(14)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(rowModel.isPinned ? Color(im4Hex: 0xFFF8E2) : .white.opacity(0.90))
                if rowModel.isPinned {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(IMColor.warning)
                        .frame(width: 4)
                        .padding(.vertical, 15)
                        .padding(.leading, 1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(rowModel.isPinned ? IMColor.warning.opacity(0.38) : IMColor.line)
            )
            .shadow(color: rowModel.isPinned ? IMColor.warning.opacity(0.10) : .clear, radius: 10, y: 5)
        )
    }

    private var summaryText: Text {
        guard let unreadMention else {
            return Text(rowModel.lastMessage).foregroundColor(IMColor.muted)
        }
        let prefix = unreadMention.senderName.isEmpty ? "" : "\(unreadMention.senderName)："
        return Text(prefix).foregroundColor(IMColor.muted) + highlightedMentionText(unreadMention.text, target: mentionTarget, baseColor: IMColor.muted)
    }
}

private struct ConversationStatusChip: View {
    let symbol: String
    let title: String
    let color: Color
    let fill: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
            Text(title)
                .font(.system(size: 9, weight: .black))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(color.opacity(0.24), lineWidth: 0.8))
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

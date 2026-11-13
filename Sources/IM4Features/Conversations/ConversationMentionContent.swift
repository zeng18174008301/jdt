// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4Domain
import IM4DesignSystem

public struct ConversationMentionMessageRecord: Identifiable, Sendable {
    public let id: String
    public let conversationID: String
    public let conversationTitle: String
    public let conversationKind: ConversationKind
    public let messageID: String
    public let channelSeq: Int64
    public let senderUID: String
    public let senderName: String
    public let senderSeed: UInt
    public let senderAvatarURL: String
    public let senderAvatarVersion: String
    public let senderAvatarUpdatedAt: String
    public let text: String
    public let time: String
    public let isUnread: Bool
    public let unreadCount: Int
    public let sortScore: Int

    public init(id: String, conversationID: String, conversationTitle: String,
                conversationKind: ConversationKind, messageID: String, channelSeq: Int64,
                senderUID: String, senderName: String, senderSeed: UInt,
                senderAvatarURL: String, senderAvatarVersion: String, senderAvatarUpdatedAt: String,
                text: String, time: String, isUnread: Bool,
                unreadCount: Int, sortScore: Int) {
        self.id = id
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.conversationKind = conversationKind
        self.messageID = messageID
        self.channelSeq = channelSeq
        self.senderUID = senderUID
        self.senderName = senderName
        self.senderSeed = senderSeed
        self.senderAvatarURL = senderAvatarURL
        self.senderAvatarVersion = senderAvatarVersion
        self.senderAvatarUpdatedAt = senderAvatarUpdatedAt
        self.text = text
        self.time = time
        self.isUnread = isUnread
        self.unreadCount = unreadCount
        self.sortScore = sortScore
    }
}

public struct MentionMessageListContent<Row: View>: View {
    let records: [ConversationMentionMessageRecord]
    let row: (ConversationMentionMessageRecord) -> Row

    public init(records: [ConversationMentionMessageRecord], @ViewBuilder row: @escaping (ConversationMentionMessageRecord) -> Row) {
        self.records = records
        self.row = row
    }

    public var body: some View {
        if records.isEmpty {
            EmptyStateView(symbol: "at", title: "暂无 @ 我的消息", subtitle: "群聊里有人提到你时，会按最新时间展示在这里。")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("@ 我的消息")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(IMColor.ink)
                    Spacer()
                    Text("新消息在上方")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }
                .padding(.horizontal, 2)

                ForEach(records) { record in
                    row(record)
                }
            }
        }
    }
}

public struct MentionMessageRowContent<Avatar: View, Certification: View>: View {
    let record: ConversationMentionMessageRecord
    let mentionTarget: String

    let avatar: () -> Avatar
    let certification: () -> Certification

    public init(record: ConversationMentionMessageRecord, mentionTarget: String,
                @ViewBuilder avatar: @escaping () -> Avatar, @ViewBuilder certification: @escaping () -> Certification) {
        self.record = record
        self.mentionTarget = mentionTarget
        self.avatar = avatar
        self.certification = certification
    }

    private var conversationTag: (title: String, color: Color)? {
        switch record.conversationKind {
        case .group:
            return ("群", IMColor.warning)
        case .system:
            return ("系", IMColor.cyan)
        case .direct:
            return nil
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                avatar()
                if let conversationTag {
                    ConversationTypeBadge(title: conversationTag.title, color: conversationTag.color)
                        .offset(x: 2, y: -3)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(record.senderName)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(IMColor.ink)
                        .lineLimit(1)
                    certification()
                    if record.isUnread, let unreadText = UnreadBadgeFormatter.text(record.unreadCount) {
                        Text(unreadText)
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(IMColor.danger))
                            .accessibilityLabel("未读 \(unreadText) 条")
                    }
                    Spacer(minLength: 6)
                    Text(record.time)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IMColor.muted)
                }

                mentionSnippetText
                    .font(.system(size: 14, weight: .semibold))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Text(record.conversationTitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(IMColor.muted)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(IMColor.muted.opacity(0.55))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(IMColor.brand.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var mentionSnippetText: Text {
        if record.isUnread {
            return highlightedMentionText(record.text, target: mentionTarget, baseColor: IMColor.ink)
        }
        return Text(record.text).foregroundColor(IMColor.muted)
    }
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

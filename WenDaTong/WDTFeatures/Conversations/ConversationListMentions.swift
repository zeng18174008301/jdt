import SwiftUI // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import UIKit
import IM4Features

extension ConversationListView {
    // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112
    func renderMentionRecords(in conversations: [ConversationMessageSnapshot]) -> [MentionMessageRecord] {
        let records = conversations
            .flatMap { conversation -> [MentionMessageRecord] in
                let unreadMentions = unreadMentionMessages(in: conversation)
                // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：未读 mention 用 Set 判断，避免 @我 列表逐条 contains 扫描
                let unreadMentionIDs = Set(unreadMentions.map(\.id).filter { !$0.isEmpty })
                let hasUnreadMentionWithEmptyID = unreadMentions.contains { $0.id.isEmpty }
                // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
                var records = conversation.messages.enumerated().compactMap { index, message -> MentionMessageRecord? in
                    guard isMentionMessage(message), mentionMatchesQuery(message, in: conversation) else { return nil }
                    let sender = conversation.participants.first { $0.id == message.senderId }
                    let displaySenderName = mentionSenderDisplayName(for: message)
                    let isUnread = message.id.isEmpty
                        ? hasUnreadMentionWithEmptyID
                        : unreadMentionIDs.contains(message.id)
                    return MentionMessageRecord(
                        id: "\(conversation.id)-\(message.id)",
                        conversationID: conversation.id,
                        conversationTitle: conversationDisplayTitle(for: conversation),
                        conversationKind: conversation.kind,
                        messageID: message.id,
                        channelSeq: message.channelSeq,
                        senderUID: message.senderId,
                        senderName: displaySenderName,
                        senderSeed: sender?.avatarSeed ?? stableMentionSenderSeed(message.senderId.isEmpty ? message.senderName : message.senderId),
                        senderAvatarURL: message.senderAvatarURL,
                        senderAvatarVersion: message.senderAvatarVersion,
                        senderAvatarUpdatedAt: message.senderAvatarUpdatedAt,
                        text: message.text,
                        time: message.time,
                        isUnread: isUnread,
                        unreadCount: isUnread ? unreadMentions.count : 0,
                        sortScore: mentionSortScore(message: message, conversation: conversation, index: index)
                    )
                }
                if let summaryRecord = mentionSummaryRecord(in: conversation),
                   !records.contains(where: { record in
                       (!summaryRecord.messageID.isEmpty && record.messageID == summaryRecord.messageID)
                           || (summaryRecord.channelSeq > 0 && record.channelSeq == summaryRecord.channelSeq)
                   }) {
                    records.append(summaryRecord)
                }
                return records
            }
            .sorted { $0.sortScore > $1.sortScore }
        return Array(records.prefix(30))
    }

    // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_BEGIN
    func listUnreadMentionCount(in conversation: ConversationMessageSnapshot) -> Int {
        max(unreadMentionMessageCount(in: conversation), conversation.hasMention ? max(1, conversation.mentionCount) : 0)
    }
    // WDT_IOS1_CONVERSATION_LIST_ROW_UPDATES_20261112_END

    var mentionTarget: String {
        "@\(state.currentUser.name)"
    }

    private func isMentionMessage(_ message: ChatMessage) -> Bool {
        MessageMentionProjection.includes(message, currentActor: state.currentUser)
    }

    private func mentionSummaryRecord(in conversation: ConversationMessageSnapshot) -> MentionMessageRecord? {
        guard conversation.hasMention,
              !conversation.mentionSummaryText.isEmpty,
              mentionSummaryMatchesQuery(conversation) else { return nil }
        let directPeer = conversation.kind == .direct
            ? state.directConversationProfilePeer(for: conversation)
            : nil
        return MentionMessageRecord(
            id: "\(conversation.id)-mention-summary-\(conversation.mentionSummaryMessageID.isEmpty ? String(conversation.mentionSummaryChannelSeq) : conversation.mentionSummaryMessageID)",
            conversationID: conversation.id,
            conversationTitle: conversationDisplayTitle(for: conversation),
            conversationKind: conversation.kind,
            messageID: conversation.mentionSummaryMessageID,
            channelSeq: conversation.mentionSummaryChannelSeq,
            senderUID: "",
            senderName: conversationDisplayTitle(for: conversation),
            senderSeed: stableMentionSenderSeed(conversation.id),
            senderAvatarURL: conversation.kind == .group ? conversation.avatarURL : directPeer?.displayAvatarURL ?? "",
            senderAvatarVersion: conversation.kind == .group ? conversation.avatarVersion : directPeer?.avatarVersion ?? "",
            senderAvatarUpdatedAt: conversation.kind == .group ? conversation.avatarUpdatedAt : directPeer?.avatarUpdatedAt ?? "",
            text: conversation.mentionSummaryText,
            time: conversation.time,
            isUnread: true,
            unreadCount: max(1, conversation.mentionCount),
            sortScore: Int(conversation.mentionSummaryChannelSeq) + 90_000
        )
    }

    func mentionJumpTarget(for record: MentionMessageRecord) -> RemoteTenantSearchJumpTarget? {
        let messageID = record.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelSeq = record.channelSeq > 0 ? record.channelSeq : nil
        guard !messageID.isEmpty || channelSeq != nil else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: record.conversationID,
            channelType: mentionJumpChannelType(record.conversationKind),
            channelSeq: channelSeq,
            messageID: messageID.isEmpty ? nil : messageID
        )
    }

    private func mentionJumpChannelType(_ kind: ConversationKind) -> String {
        switch kind {
        case .group: return "group"
        case .system: return "system"
        case .direct: return "direct"
        }
    }

    private func mentionSummaryMatchesQuery(_ conversation: ConversationMessageSnapshot) -> Bool {
        let keyword = trimmedSearchQuery
        guard !keyword.isEmpty else { return true }
        let displayTitle = conversationDisplayTitle(for: conversation)
        return conversation.mentionSummaryText.localizedCaseInsensitiveContains(keyword)
            || conversation.title.localizedCaseInsensitiveContains(keyword)
            || displayTitle.localizedCaseInsensitiveContains(keyword)
    }

    private func mentionMatchesQuery(_ message: ChatMessage, in conversation: ConversationMessageSnapshot) -> Bool {
        let keyword = trimmedSearchQuery
        guard !keyword.isEmpty else { return true }
        let displayTitle = conversationDisplayTitle(for: conversation)
        return message.text.localizedCaseInsensitiveContains(keyword)
            || mentionSenderDisplayName(for: message).localizedCaseInsensitiveContains(keyword)
            || conversation.title.localizedCaseInsensitiveContains(keyword)
            || displayTitle.localizedCaseInsensitiveContains(keyword)
    }

    private func mentionSortScore(message: ChatMessage, conversation: ConversationMessageSnapshot, index: Int) -> Int {
        let source = "\(conversation.time) \(message.time)"
        let dayBase: Int
        if source.contains("刚刚") {
            dayBase = 50_000
        } else if source.contains("今天") || (source.contains(":") && !source.contains("周一") && !source.contains("昨天")) {
            dayBase = 40_000
        } else if source.contains("昨天") {
            dayBase = 30_000
        } else if source.contains("周一") {
            dayBase = 10_000
        } else {
            dayBase = 0
        }
        return dayBase + timeMinutes(in: source) + index
    }

    private func stableMentionSenderSeed(_ value: String) -> UInt {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt = 2_166_136_261
        for byte in normalized.utf8 {
            hash ^= UInt(byte)
            hash &*= 16_777_619
        }
        return hash
    }

    func timeMinutes(in text: String) -> Int {
        for token in text.split(separator: " ") where token.contains(":") {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { continue }
            return hour * 60 + minute
        }
        return 0
    }

    func latestUnreadMention(in conversation: ConversationMessageSnapshot) -> MentionPreview? {
        if conversation.hasMention, !conversation.mentionSummaryText.isEmpty {
            if let message = conversation.messages.last(where: {
                (!conversation.mentionSummaryMessageID.isEmpty && $0.id == conversation.mentionSummaryMessageID)
                    || (conversation.mentionSummaryChannelSeq > 0 && $0.channelSeq == conversation.mentionSummaryChannelSeq)
            }), let label = message.conversationAttachmentPreview {
                return MentionPreview(senderName: "", text: label)
            }
            return MentionPreview(senderName: conversationDisplayTitle(for: conversation), text: conversation.mentionSummaryText)
        }
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：直接取最新未读 mention，避免为列表行预览构造临时数组
        return latestUnreadMentionMessage(in: conversation).map { message in
            if let label = message.conversationAttachmentPreview {
                return MentionPreview(senderName: "", text: label)
            }
            return MentionPreview(senderName: mentionSenderDisplayName(for: message), text: message.text)
        }
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
    }

    func earliestUnreadMentionJumpTarget(in conversation: ConversationMessageSnapshot) -> RemoteTenantSearchJumpTarget? {
        // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：点击跳转直接查找最早未读 mention，避免生成数组
        if let message = firstUnreadMentionMessage(in: conversation) {
            return RemoteTenantSearchJumpTarget(
                kind: "message",
                channelID: conversation.id,
                channelType: mentionJumpChannelType(conversation.kind),
                channelSeq: message.channelSeq > 0 ? message.channelSeq : nil,
                messageID: message.id.isEmpty ? nil : message.id
            )
        }
        // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
        guard conversation.hasMention,
              !conversation.mentionSummaryText.isEmpty,
              (!conversation.mentionSummaryMessageID.isEmpty || conversation.mentionSummaryChannelSeq > 0) else { return nil }
        return RemoteTenantSearchJumpTarget(
            kind: "message",
            channelID: conversation.id,
            channelType: mentionJumpChannelType(conversation.kind),
            channelSeq: conversation.mentionSummaryChannelSeq > 0 ? conversation.mentionSummaryChannelSeq : nil,
            messageID: conversation.mentionSummaryMessageID.isEmpty ? nil : conversation.mentionSummaryMessageID
        )
    }

    private func mentionSenderDisplayName(for message: ChatMessage) -> String {
        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.remarkPreferredDisplayName(
            identifiers: [message.senderId],
            candidates: [storedName],
            fallback: storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName
        )
    }

    private func unreadMentionMessages(in conversation: ConversationMessageSnapshot) -> [ChatMessage] {
        if conversation.lastReadSeq > 0 {
            return conversation.messages.filter { message in
                message.channelSeq > conversation.lastReadSeq && isMentionMessage(message)
            }
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return [] }
        return conversation.messages
            .suffix(unreadCount)
            .filter { isMentionMessage($0) }
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改开始：未读 mention 扫描复用，保持原筛选语义但减少数组分配
    private func firstUnreadMentionMessage(in conversation: ConversationMessageSnapshot) -> ChatMessage? {
        if conversation.lastReadSeq > 0 {
            for message in conversation.messages where message.channelSeq > conversation.lastReadSeq && isMentionMessage(message) {
                return message
            }
            return nil
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return nil }
        for message in conversation.messages.suffix(unreadCount) where isMentionMessage(message) {
            return message
        }
        return nil
    }

    private func latestUnreadMentionMessage(in conversation: ConversationMessageSnapshot) -> ChatMessage? {
        if conversation.lastReadSeq > 0 {
            for message in conversation.messages.reversed() where message.channelSeq > conversation.lastReadSeq && isMentionMessage(message) {
                return message
            }
            return nil
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return nil }
        for message in conversation.messages.suffix(unreadCount).reversed() where isMentionMessage(message) {
            return message
        }
        return nil
    }

    private func unreadMentionMessageCount(in conversation: ConversationMessageSnapshot) -> Int {
        if conversation.lastReadSeq > 0 {
            var count = 0
            for message in conversation.messages where message.channelSeq > conversation.lastReadSeq && isMentionMessage(message) {
                count += 1
            }
            return count
        }
        let unreadCount = min(max(conversation.unread, 0), conversation.messages.count)
        guard unreadCount > 0 else { return 0 }
        var count = 0
        for message in conversation.messages.suffix(unreadCount) where isMentionMessage(message) {
            count += 1
        }
        return count
    }
    // JHT_MOD_END CONVERSATION_LIST_DATA_SCALE_PERF_20260912 - 修改结束
}

typealias MentionMessageRecord = IM4Features.ConversationMentionMessageRecord

typealias MentionPreview = IM4Features.ConversationMentionPreview

struct MentionMessageList: View {
    @EnvironmentObject private var state: AppState

    let records: [MentionMessageRecord]
    let mentionTarget: String
    var openRecord: (MentionMessageRecord) -> Void

    var body: some View {
        MentionMessageListContent(records: records) { record in
            Button {
                openRecord(record)
            } label: {
                MentionMessageRow(record: record, mentionTarget: mentionTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mention_message_row_\(record.id)")
            .certificationAccessibilityLabel(
                "@我消息 \(record.senderName)",
                reference: state.certificationPillSource.reference(forExactUID: record.senderUID)
            ) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }
    }
}

private struct MentionMessageRow: View {
    @EnvironmentObject private var state: AppState
    let record: MentionMessageRecord
    let mentionTarget: String

    var body: some View {
        MentionMessageRowContent(record: record, mentionTarget: mentionTarget, avatar: {
            AvatarView(name: record.senderName, seed: record.senderSeed, size: 44, imageURL: record.senderAvatarURL, avatarVersion: record.senderAvatarVersion, avatarUpdatedAt: record.senderAvatarUpdatedAt, certificationReference: state.certificationPillSource.reference(forExactUID: record.senderUID)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
        }, certification: { CertificationPillView(exactUID: record.senderUID, compact: true) })
    }
}

// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
func highlightedMentionText(_ text: String, target: String, baseColor: Color) -> Text {
    IM4Features.highlightedMentionText(text, target: target, baseColor: baseColor)
}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

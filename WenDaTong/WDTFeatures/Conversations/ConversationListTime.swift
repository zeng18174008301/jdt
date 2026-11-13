// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import Foundation
import IM4Features

func conversationListDisplayTimestamp(_ time: String, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval? {
    IM4Features.featureConversationListDisplayTimestamp(time, now: now, calendar: calendar)
}
func conversationListDisplayTime(rawTime: String, sortTimestamp: TimeInterval, now: Date = Date(), calendar: Calendar = .current) -> String {
    IM4Features.featureConversationListDisplayTime(rawTime: rawTime, sortTimestamp: sortTimestamp, now: now, calendar: calendar)
}
func conversationListNormalizedTimestamp(_ timestamp: TimeInterval, now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
    IM4Features.featureConversationListNormalizedTimestamp(timestamp, now: now, calendar: calendar)
}
// WDT_CONVERSATION_LIST_SORT_20261021_BEGIN: read-only list projection; never change stored summaries or sync cursors.
func conversationListMessageTimestamp(_ conversation: ConversationMessageSnapshot) -> TimeInterval? {
    guard conversation.kind != .system,
          let tail = conversation.messages.last(where: { !$0.isPinnedContextOnly }),
          tail.status != .sending,
          tail.status != .failed,
          tail.channelSeq >= conversation.lastMsgSeq else { return nil }

    var expectedSeq = tail.channelSeq
    let visibleFromSeq = max(1, conversation.historyVisibleFromSeq)
    for message in conversation.messages.reversed() {
        guard !message.isPinnedContextOnly,
              message.status != .sending,
              message.status != .failed else { continue }
        // A gap may contain a newer surviving message. Keep the existing summary time until loaded.
        guard expectedSeq <= 0 || message.channelSeq == expectedSeq else { return nil }
        if !message.isDeletedLocally {
            // Recall keeps the original message time, not the time of the recall operation.
            guard let timestamp = message.createdAt?.timeIntervalSince1970,
                  timestamp.isFinite, timestamp > 0 else { return nil }
            return timestamp
        }
        guard expectedSeq > 0 else { return nil }
        expectedSeq -= 1
        if expectedSeq < visibleFromSeq {
            return 0
        }
    }
    return nil
}

func conversationListDisplayTime(for conversation: ConversationMessageSnapshot, now: Date = Date(), calendar: Calendar = .current) -> String {
    let messageTimestamp = conversationListMessageTimestamp(conversation)
    return conversationListDisplayTime(
        rawTime: messageTimestamp == 0 ? "" : conversation.time,
        sortTimestamp: messageTimestamp ?? conversation.sortTimestamp,
        now: now,
        calendar: calendar
    )
}
// WDT_CONVERSATION_LIST_SORT_20261021_END
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

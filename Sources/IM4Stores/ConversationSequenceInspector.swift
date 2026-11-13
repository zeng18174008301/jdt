import Foundation
import IM4Domain
import IM4Data

public enum ConversationSequenceInspector: Sendable {
    // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：复用单次扫描，避免 map().max() 生成临时数组
    public static func maximumInt64<S: Sequence>(_ values: S) -> Int64? where S.Element == Int64 {
        var latest: Int64?
        for value in values {
            if let current = latest {
                if value > current {
                    latest = value
                }
            } else {
                latest = value
            }
        }
        return latest
    }

    public static func maximumChannelSeq(in messages: [ChatMessage]) -> Int64? {
        maximumInt64(messages.lazy.map(\.channelSeq))
    }

    public static func maximumChannelSeq(in remoteMessages: [RemoteMessage]) -> Int64? {
        maximumInt64(remoteMessages.lazy.map(\.channelSeq))
    }
    // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束

    public static func latestKnownSequence(for conversation: ConversationMessageSnapshot) -> Int64 {
        var latest = max(
            conversation.lastMsgSeq,
            conversation.messageCoveredThroughSeq,
            conversation.lastReadSeq,
            conversation.firstUnreadSeq,
            conversation.unreadAnchorSeq,
            conversation.mentionSummaryChannelSeq
        )
        for message in conversation.messages where message.channelSeq > latest {
            latest = message.channelSeq
        }
        return latest
    }

    public static func latestKnownSequence(for remote: RemoteConversation) -> Int64 {
        max(
            remote.lastMsgSeq,
            remote.lastReadSeq,
            remote.firstUnreadSeq,
            remote.unreadAnchorSeq,
            remote.mentionSummary?.channelSeq ?? 0,
            remote.lastMessage?.channelSeq ?? 0
        )
    }

    public static func latestKnownSequence(for remoteMessages: [RemoteMessage]) -> Int64 {
        var latest: Int64 = 0
        for message in remoteMessages where message.channelSeq > latest {
            latest = message.channelSeq
        }
        return latest
    }
}

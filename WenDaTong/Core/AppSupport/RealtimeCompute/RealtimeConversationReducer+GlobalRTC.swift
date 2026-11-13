import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension RealtimeConversationReducer {
    func conversationsEnforcingGlobalRTCCallRecordExactOnce(
        _ source: [ConversationMessageSnapshot]
    ) -> [ConversationMessageSnapshot] {
        var globalRTCAuthorities: [String: (conversationID: String, authority: RTCCallRecordMessageDeduplicator.Authority)] = [:]
        return source.map { conversation in
            var normalized = conversation
            let originalLatestMessageID = latestConfirmedMessage(in: conversation.messages)?.id
            var removedOriginalLatest = false
            var messages: [ChatMessage] = []
            for message in conversation.messages {
                guard let authority = RTCCallRecordMessageDeduplicator.authority(for: message) else {
                    messages.append(message)
                    continue
                }
                if let existing = globalRTCAuthorities[authority.callID] {
                    if existing.conversationID != conversation.id || existing.authority != authority,
                       authority.channelSeq > 0 {
                        normalized.messageCoveredThroughSeq = min(
                            normalized.messageCoveredThroughSeq,
                            max(0, authority.channelSeq - 1)
                        )
                        normalized.messageCoverageRequiresRecovery = true
                    }
                    removedOriginalLatest = removedOriginalLatest || message.id == originalLatestMessageID
                    continue
                }
                globalRTCAuthorities[authority.callID] = (conversation.id, authority)
                messages.append(message)
            }
            normalized.messages = messages
            if removedOriginalLatest {
                if let latest = latestConfirmedMessage(in: messages) {
                    normalized.lastMessage = latest.conversationListPreview
                    normalized.time = latest.time
                } else {
                    normalized.lastMessage = ""
                    normalized.time = ""
                }
            }
            return normalized
        }
    }

}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

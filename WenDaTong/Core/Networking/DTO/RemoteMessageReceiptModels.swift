import Foundation
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteReadAckResponse = IM4Data.RemoteReadAckResponse
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMessageReadReceiptResponse = IM4Data.RemoteMessageReadReceiptResponse

extension RemoteMessageReadReceiptResponse {
    var hasReceiptDetails: Bool {
        readCount != nil
            || unreadCount != nil
            || memberCount != nil
            || targetCount != nil
            || !items.isEmpty
            || !unreadItems.isEmpty
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMessageReadParticipant = IM4Data.RemoteMessageReadParticipant
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMessageReceipt = IM4Data.RemoteMessageReceipt
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMessageReceiptSyncResult = IM4Data.RemoteMessageReceiptSyncResult
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMessageReactionReceipt = IM4Data.RemoteMessageReactionReceipt

extension RemoteMessageReactionReceipt {
    var operatorName: String {
        payload["nickname"]?.stringValue
            ?? payload["display_name"]?.stringValue
            ?? payload["operator_name"]?.stringValue
            ?? payload["actor_name"]?.stringValue
            ?? ""
    }
}
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

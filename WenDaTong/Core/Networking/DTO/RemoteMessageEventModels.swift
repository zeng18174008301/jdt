import IM4Stores
import Foundation
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteConversationSettingsResponse = IM4Data.RemoteConversationSettingsResponse
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteExtraResponse = IM4Data.RemoteExtraResponse
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteMessageExtra = IM4Data.RemoteMessageExtra

// Pure message-extra identity helpers are implemented in IM4Stores.
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_BEGIN
typealias RemoteConversationReadWatermark = IM4Data.RemoteConversationReadWatermark
// WDT_IOS1_DATA_CONVERSATION_MESSAGE_EVENT_DTO_20261110_END

struct RealtimeEnvelope: Decodable, Sendable, IM4Data.RealtimeBatchWireFrame { // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
    var decodedMessage: RealtimeDecodedMessage? = nil
    var decodedSidecar: RealtimeDecodedSidecar? = nil // WDT_IOS1_REALTIME_SIDECAR_DECODE_20261111
    // Gateway notifications are wakeups, never authority to display or end a call.
    var isRTCCallNotification: Bool {
        guard type == "notification" else { return false }
        return ["type", "kind"].contains { key in
            payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call"
        }
    }

    // WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111_BEGIN
    private let wire: IM4Data.RealtimeWireEnvelope
    var type: String { wire.type }
    var requestID: String? { wire.requestID }
    var payload: [String: JSONValue] { wire.payload }

    init(type: String, requestID: String?, payload: [String: JSONValue]) {
        wire = IM4Data.RealtimeWireEnvelope(type: type, requestID: requestID, payload: payload)
    }

    init(from decoder: Decoder) throws {
        wire = try IM4Data.RealtimeWireEnvelope(from: decoder)
    }
    // WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111_END
} // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END

// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import IM4Stores

typealias RealtimeDerivationStamp = IM4Stores.RealtimeDerivationStamp

// App owns extraction/interpretation of RTC business records; Store owns only token mechanics.
enum ConversationMemoryRTCPolicy {
    nonisolated static func rtcAuthorities(_ rows: [ChatMessage]) -> [String: [RTCCallRecordMessageDeduplicator.Authority]] {
        var result: [String: [RTCCallRecordMessageDeduplicator.Authority]] = [:]
        for row in rows {
            if let value = RTCCallRecordMessageDeduplicator.authority(for: row) { result[value.callID, default: []].append(value) }
        }
        return result
    }
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
extension ConversationStore {


    func realtimeGlobalRTCAuthorities(excluding target: String?, keys: Set<String>) -> [String: RTCCallRecordMessageDeduplicator.Authority] {
        guard !keys.isEmpty else { return [:] }
        let stamp = realtimeDerivationStamp // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110: opaque value, no private index exposure.
        var result: [String: RTCCallRecordMessageDeduplicator.Authority] = [:]
        for row in conversations where row.id != target && stamp.hasRTCKeys(in: row.id, matching: keys) {
            for message in conversationMessageSnapshot(id: row.id)?.messages ?? [] {
                guard let authority = RTCCallRecordMessageDeduplicator.authority(for: message), keys.contains(authority.callID),
                      result[authority.callID] == nil else { continue }
                result[authority.callID] = authority
            }
        }
        return result
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

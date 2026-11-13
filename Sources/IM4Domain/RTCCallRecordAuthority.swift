// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
import Foundation

public struct RTCCallRecordAuthority: Hashable, Sendable {
    public let callID: String
    public let messageID: String
    public let channelSeq: Int64
    let senderID: String
    let isOutgoing: Bool
    let contentType: String
    let record: RTCCallRecordPayload

    public init(callID: String, messageID: String, channelSeq: Int64, senderID: String, isOutgoing: Bool, contentType: String, record: RTCCallRecordPayload) {
        self.callID = callID
        self.messageID = messageID
        self.channelSeq = channelSeq
        self.senderID = senderID
        self.isOutgoing = isOutgoing
        self.contentType = contentType
        self.record = record
    }
}
// WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END

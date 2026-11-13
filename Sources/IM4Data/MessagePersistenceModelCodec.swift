// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain

public protocol MessagePersistenceModelCodec: Sendable {
    func conversation(from record: CachedConversation) -> ConversationMessageSnapshot
    func message(from record: CachedMessage) -> ChatMessage
    func sanitizedForDurableOutbox(_ record: CachedMessage) -> CachedMessage
    func peerUID(from record: RTCCallRecordPayload, viewerIsCaller: Bool) -> String
}
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

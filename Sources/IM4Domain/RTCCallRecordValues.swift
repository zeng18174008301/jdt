// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

public enum RTCCallRecordType: String, Codable, Hashable, Sendable {
    case audio
    case video

}

public enum RTCCallRecordOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case completed
    case callerCanceled = "caller_canceled"
    case calleeRejected = "callee_rejected"
    case noAnswer = "no_answer"
    case busy
    case setupFailed = "setup_failed"
    case interrupted
}

public struct RTCCallRecordPayload: Codable, Hashable, Sendable {

    // Preserve the original synthesized memberwise parameter order/defaults.
    public init(
        schemaVersion: Int,
        callID: String,
        callType: RTCCallRecordType,
        callerUID: String,
        calleeUID: String,
        finalOutcome: RTCCallRecordOutcome,
        startedAt: Date,
        answeredAt: Date?,
        mediaConnectedAt: Date?,
        endedAt: Date,
        durationSeconds: Int,
        reasonCode: String,
        fallbackText: String,
        endActorUID: String?,
        finalMediaMode: String?
    ) {
        self.schemaVersion = schemaVersion
        self.callID = callID
        self.callType = callType
        self.callerUID = callerUID
        self.calleeUID = calleeUID
        self.finalOutcome = finalOutcome
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.mediaConnectedAt = mediaConnectedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.reasonCode = reasonCode
        self.fallbackText = fallbackText
        self.endActorUID = endActorUID
        self.finalMediaMode = finalMediaMode
    }
    public let schemaVersion: Int
    public let callID: String
    public let callType: RTCCallRecordType
    public let callerUID: String
    public let calleeUID: String
    public let finalOutcome: RTCCallRecordOutcome
    public let startedAt: Date
    public let answeredAt: Date?
    public let mediaConnectedAt: Date?
    public let endedAt: Date
    public let durationSeconds: Int
    public let reasonCode: String
    public let fallbackText: String
    public let endActorUID: String?
    public let finalMediaMode: String?

}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

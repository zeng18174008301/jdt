// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation

public enum RemoteRTCSignalKind: Codable, Sendable, Equatable {
    case offer
    case answer
    case candidate
    case iceComplete
    case iceRestart
    case renegotiate
    case mediaState
    case bye
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .offer: return "offer"
        case .answer: return "answer"
        case .candidate: return "candidate"
        case .iceComplete: return "ice_complete"
        case .iceRestart: return "ice_restart"
        case .renegotiate: return "renegotiate"
        case .mediaState: return "media_state"
        case .bye: return "bye"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "offer": self = .offer
        case "answer": self = .answer
        case "candidate": self = .candidate
        case "ice_complete": self = .iceComplete
        case "ice_restart": self = .iceRestart
        case "renegotiate": self = .renegotiate
        case "media_state", "media-state": self = .mediaState
        case "bye": self = .bye
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RTCVoiceMediaState: String, Codable, Sendable, Equatable {
    case preparing
    case signaling
    case connecting
    case connected
    case unstable
    case failed
    case closed


}

public enum RTCVoiceMediaEvent: String, Codable, Sendable, Equatable {
    case callAccepted
    case roomJoined
    case localTrackReady
    case remoteAudioTrackReady
    case remoteAudioRTPReady
    case localDescriptionSet
    case remoteDescriptionSet
    case iceChecking
    case iceConnected
    case iceCompleted
    case peerConnectionConnected
    case connectionRecovered
    case iceDisconnected
    case iceFailed
    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：区分本机媒体启动失败与真实 ICE 失败
    case mediaStartFailed
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    case recoveryExhausted
    case closed




}

public enum RTCVoIPPushDeliveryFreshness: Equatable, Sendable {
    case unknown
    case fresh
    case expired
    case invalidWindow
}

public struct RTCIcePolicy: Sendable, Equatable {
    public enum Transport: String, Decodable, Sendable { case all, relay }
    public let transport: Transport
    public let version: Int
    public let revision: String

    public init(transport: Transport, version: Int, revision: String) {
        self.transport = transport
        self.version = version
        self.revision = revision
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

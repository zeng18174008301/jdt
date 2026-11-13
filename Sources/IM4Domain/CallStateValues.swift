// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Foundation

public enum CallRecordDirection: String, Hashable, Codable, Sendable {
    case outgoing
    case incoming
    case system
}

public struct CallRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let callID: String?
    public let peerID: String
    public let peerUserID: String
    public let peerAvatarURL: String
    public let peerAvatarVersion: String
    public let peerAvatarUpdatedAt: String
    public let peerAvatarSource: String
    public let title: String
    public let subtitle: String
    public let time: String
    public let status: String
    public let direction: CallRecordDirection
    public let callType: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let durationSeconds: TimeInterval?
    public let endReason: String
    public let stateVersion: Int64

    public init(
        id: String,
        callID: String? = nil,
        peerID: String = "",
        peerUserID: String = "",
        peerAvatarURL: String = "",
        peerAvatarVersion: String = "",
        peerAvatarUpdatedAt: String = "",
        peerAvatarSource: String = "",
        title: String,
        subtitle: String,
        time: String,
        status: String,
        direction: CallRecordDirection = .outgoing,
        callType: String = "语音通话",
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        endReason: String = "",
        stateVersion: Int64 = 0
    ) {
        self.id = id
        self.callID = callID
        self.peerID = peerID
        self.peerUserID = peerUserID
        self.peerAvatarURL = peerAvatarURL
        self.peerAvatarVersion = peerAvatarVersion
        self.peerAvatarUpdatedAt = peerAvatarUpdatedAt
        self.peerAvatarSource = peerAvatarSource
        self.title = title
        self.subtitle = subtitle
        self.time = time
        self.status = status
        self.direction = direction
        self.callType = callType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.endReason = endReason
        self.stateVersion = stateVersion
    }
}

public struct IncomingVoiceCall: Identifiable, Hashable {
    public let id: String
    public var callID: String? = nil
    public var caller: IMUser
    public let startedAt: String
    public var source: String
    public var requestedMediaMode: String = "audio"
    public var stateVersion: Int64 = 0

    public var isVideo: Bool {
        requestedMediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
    }

    public init(
        id: String,
        callID: String? = nil,
        caller: IMUser,
        startedAt: String,
        source: String,
        requestedMediaMode: String = "audio",
        stateVersion: Int64 = 0
    ) {
        self.id = id
        self.callID = callID
        self.caller = caller
        self.startedAt = startedAt
        self.source = source
        self.requestedMediaMode = requestedMediaMode
        self.stateVersion = stateVersion
    }
}

public enum VideoCallCameraPosition: String, Hashable {
    case front
    case back
}

public struct VideoCallPreview: Identifiable, Hashable {
    public let id: String
    public var peer: IMUser
    public var channelID: String?
    public var cameraEnabled: Bool
    public var isPreparing: Bool
    public var unavailableReason: String?
    public var isStartingCall: Bool = false
    public var startError: String? = nil

    public init(
        id: String,
        peer: IMUser,
        channelID: String? = nil,
        cameraEnabled: Bool,
        isPreparing: Bool,
        unavailableReason: String? = nil,
        isStartingCall: Bool = false,
        startError: String? = nil
    ) {
        self.id = id
        self.peer = peer
        self.channelID = channelID
        self.cameraEnabled = cameraEnabled
        self.isPreparing = isPreparing
        self.unavailableReason = unavailableReason
        self.isStartingCall = isStartingCall
        self.startError = startError
    }
}

public struct VideoCallTerminalResult: Identifiable, Hashable {
    public let id: String
    public let callID: String
    public let peer: IMUser
    public let title: String
    public let cause: String
    public let nextAction: String
    public let reason: String
    public let durationText: String


    public init(
        id: String,
        callID: String,
        peer: IMUser,
        title: String,
        cause: String,
        nextAction: String,
        reason: String,
        durationText: String
    ) {
        self.id = id
        self.callID = callID
        self.peer = peer
        self.title = title
        self.cause = cause
        self.nextAction = nextAction
        self.reason = reason
        self.durationText = durationText
    }
}

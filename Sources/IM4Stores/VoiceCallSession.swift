// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Foundation
import IM4Domain

public struct VoiceCallSession: Identifiable, Hashable {
    public let id: String
    public var callID: String? = nil
    public var roomID: String = ""
    public var rtcToken: String = ""
    public var mediaBaseURL: String = ""
    public var peer: IMUser
    public let direction: String
    public let startedAt: String
    public var statusText: String = "连接中"
    public var mediaState: RTCVoiceMediaState = .preparing
    public var isMuted: Bool
    public var speakerOn: Bool
    public var startedAtDate: Date = Date()
    public var connectedAt: Date? = nil
    public var requestedMediaMode: String = "audio"
    public var mediaMode: String = "audio"
    public var localCameraEnabled: Bool = false
    public var remoteCameraEnabled: Bool = true
    public var cameraPosition: VideoCallCameraPosition = .front
    public var isMinimized: Bool = false
    public var isRecoveringNetwork: Bool = false
    public var voiceTransportConnected: Bool = false
    public var remoteAudioTrackReady: Bool = false
    public var remoteAudioRTPReady: Bool = false
    public var remoteVideoTrackReady: Bool = false
    public var videoConnectionGate: RTCVideoConnectionGate = RTCVideoConnectionGate()
    public var endedReason: String = ""
    public var stateVersion: Int64 = 0
    public var requiresAcceptedDeviceBeforeJoin: Bool = false

    public var isVideoCall: Bool {
        requestedMediaMode == "video" || mediaMode == "video"
    }

    public init(
        id: String,
        callID: String? = nil,
        roomID: String = "",
        rtcToken: String = "",
        mediaBaseURL: String = "",
        peer: IMUser,
        direction: String,
        startedAt: String,
        statusText: String = "连接中",
        mediaState: RTCVoiceMediaState = .preparing,
        isMuted: Bool,
        speakerOn: Bool,
        startedAtDate: Date = Date(),
        connectedAt: Date? = nil,
        requestedMediaMode: String = "audio",
        mediaMode: String = "audio",
        localCameraEnabled: Bool = false,
        remoteCameraEnabled: Bool = true,
        cameraPosition: VideoCallCameraPosition = .front,
        isMinimized: Bool = false,
        isRecoveringNetwork: Bool = false,
        voiceTransportConnected: Bool = false,
        remoteAudioTrackReady: Bool = false,
        remoteAudioRTPReady: Bool = false,
        remoteVideoTrackReady: Bool = false,
        videoConnectionGate: RTCVideoConnectionGate = RTCVideoConnectionGate(),
        endedReason: String = "",
        stateVersion: Int64 = 0,
        requiresAcceptedDeviceBeforeJoin: Bool = false
    ) {
        self.id = id
        self.callID = callID
        self.roomID = roomID
        self.rtcToken = rtcToken
        self.mediaBaseURL = mediaBaseURL
        self.peer = peer
        self.direction = direction
        self.startedAt = startedAt
        self.statusText = statusText
        self.mediaState = mediaState
        self.isMuted = isMuted
        self.speakerOn = speakerOn
        self.startedAtDate = startedAtDate
        self.connectedAt = connectedAt
        self.requestedMediaMode = requestedMediaMode
        self.mediaMode = mediaMode
        self.localCameraEnabled = localCameraEnabled
        self.remoteCameraEnabled = remoteCameraEnabled
        self.cameraPosition = cameraPosition
        self.isMinimized = isMinimized
        self.isRecoveringNetwork = isRecoveringNetwork
        self.voiceTransportConnected = voiceTransportConnected
        self.remoteAudioTrackReady = remoteAudioTrackReady
        self.remoteAudioRTPReady = remoteAudioRTPReady
        self.remoteVideoTrackReady = remoteVideoTrackReady
        self.videoConnectionGate = videoConnectionGate
        self.endedReason = endedReason
        self.stateVersion = stateVersion
        self.requiresAcceptedDeviceBeforeJoin = requiresAcceptedDeviceBeforeJoin
    }
}

public struct RTCVideoConnectionGate: Sendable, Hashable {
    public init() {}
    public private(set) var peerConnectionConnected = false
    public private(set) var remoteMediaTrackReady = false
    public private(set) var didEmitConnected = false

    public mutating func apply(_ event: RTCVideoMediaEvent) -> Bool {
        switch event {
        case .remoteAudioTrackReady, .remoteVideoTrackReady:
            remoteMediaTrackReady = true
        case .mediaConnected:
            peerConnectionConnected = true
        case .reconnecting, .serverSignalTerminal, .failed, .closed:
            peerConnectionConnected = false
        default:
            break
        }
        guard peerConnectionConnected, remoteMediaTrackReady, !didEmitConnected else { return false }
        didEmitConnected = true
        return true
    }
}

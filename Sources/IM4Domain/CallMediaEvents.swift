// WDT_IOS1_CALLS_COMPLETE_STATE_FAMILY_20261111
import Foundation

public enum RTCVideoMediaEvent: String, Sendable, Equatable {
    case previewReady
    case localTrackReady
    case remoteAudioTrackReady
    case remoteVideoTrackReady
    case signaling
    case connecting
    case mediaConnected
    case reconnecting
    case connectionRecovered
    case cameraPaused
    case cameraUnavailable
    case cameraResumed
    case cameraSwitching
    case cameraSwitched
    case remoteCameraPaused
    case remoteCameraResumed
    case remoteDowngradedToAudio
    case serverSignalTerminal
    case failed
    case closed
}

import Foundation

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public enum AccessDiagnosticsOverlayConfiguration: String, Codable, Equatable, Sendable {
    case unavailable
    case disabled
    case enabled






}

public enum RemotePushTokenProvider: String, Codable, Equatable, Sendable {
    case apns
    case apnsVoIP = "apns_voip"
}

public enum RemotePushTokenSlot: String, Codable, Equatable, Sendable {
    case ordinary
    case voip
}

public enum RemotePushTokenRetirementStatus: String, Codable, Equatable, Sendable {
    case retired
    case alreadyEmpty = "already_empty"
    case superseded
}

public enum RemoteNotificationTargetKind: String, Decodable, Equatable, Sendable {
    case conversation
    case system
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

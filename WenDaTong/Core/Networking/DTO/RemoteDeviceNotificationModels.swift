import Foundation
import IM4Data
import IM4Domain
import CryptoKit

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteUserDevice = IM4Data.RemoteUserDevice
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteMyLoginLog = IM4Data.RemoteMyLoginLog
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteDeviceRegistration = IM4Data.RemoteDeviceRegistration

extension RemoteDeviceRegistration {
    static func standardIOS() -> RemoteDeviceRegistration {
        RemoteDeviceRegistration(deviceType: "ios", pushTokenType: nil, pushToken: "")
    }

    static func apns(token: String, bundleID: String, environment: String) -> RemoteDeviceRegistration {
        RemoteDeviceRegistration(
            deviceType: "ios",
            pushTokenType: "apns",
            pushToken: token,
            bundleID: bundleID,
            environment: environment
        )
    }

    static func voip(token: String, bundleID: String, environment: String) -> RemoteDeviceRegistration {
        RemoteDeviceRegistration(
            deviceType: "ios",
            pushTokenType: "voip",
            pushToken: token,
            bundleID: bundleID,
            environment: environment
        )
    }

    var requestBody: [String: Any] {
        var body: [String: Any] = ["device_type": deviceType]
        if let pushTokenType, !pushTokenType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["push_token_type"] = pushTokenType
        }
        if let pushToken {
            body["push_token"] = pushToken
        }
        if let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["bundle_id"] = bundleID
        }
        if let environment, !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["environment"] = environment
        }
        return body
    }

    var deduplicationKey: String {
        [
            deviceType,
            pushTokenType ?? "",
            pushToken ?? "",
            bundleID ?? "",
            environment ?? ""
        ].joined(separator: "|")
    }

    var tokenFingerprint: String? {
        guard let normalized = pushToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemotePushTokenProvider = IM4Domain.RemotePushTokenProvider
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemotePushTokenSlot = IM4Domain.RemotePushTokenSlot
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemotePushTokenRetirementStatus = IM4Domain.RemotePushTokenRetirementStatus
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemotePushTokenRetirementResponse = IM4Data.RemotePushTokenRetirementResponse
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteNotificationTargetKind = IM4Domain.RemoteNotificationTargetKind
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteNotificationTargetResolution = IM4Data.RemoteNotificationTargetResolution
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteInboxEntry = IM4Data.RemoteInboxEntry
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteSystemInboxReadResponse = IM4Data.RemoteSystemInboxReadResponse
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteIMReadAckTarget = IM4Data.RemoteIMReadAckTarget
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

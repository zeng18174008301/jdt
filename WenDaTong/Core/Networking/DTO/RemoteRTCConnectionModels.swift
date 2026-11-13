// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

typealias RemoteRTCProvider = IM4Data.RemoteRTCProvider

extension RemoteRTCProvider: @retroactive Decodable {

    var supportsAudio: Bool {
        callTypes.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "audio" }
    }

    var supportsVideo: Bool {
        videoSupported
            && videoCallEnabled != false
            && capabilitiesVersion == RTCDeviceCapabilities.protocolVersion
            && callTypes.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" }
    }

    enum CodingKeys: String, CodingKey {
        case iceTransportPolicyVersion = "ice_transport_policy_version"
        case callTypes = "call_types"
        case videoSupported = "video_supported"
        case voiceCallEnabled = "voice_call_enabled"
        case videoCallEnabled = "video_call_enabled"
        case capabilitiesVersion = "capabilities_version"
        case mediaPlaneConfigured = "media_plane_configured"
        case iceServersConfigured = "ice_servers_configured"
        case callTimeoutSeconds = "call_timeout_seconds"
    }

    public init(from decoder: Decoder) throws {
        let iceTransportPolicyVersion: Int?
        let callTypes: [String]
        let videoSupported: Bool
        let voiceCallEnabled: Bool?
        let videoCallEnabled: Bool?
        let capabilitiesVersion: String
        let mediaPlaneConfigured: Bool
        let iceServersConfigured: Bool
        let callTimeoutSeconds: Int?
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iceTransportPolicyVersion = c.contains(.iceTransportPolicyVersion)
            ? try c.decode(Int.self, forKey: .iceTransportPolicyVersion) : nil
        guard iceTransportPolicyVersion == nil || iceTransportPolicyVersion == 1 else {
            throw RTCIcePolicyError.invalidPolicy
        }
        callTypes = try c.decodeIfPresent([String].self, forKey: .callTypes) ?? []
        videoSupported = c.decodeLossyBoolIfPresent(forKey: .videoSupported) ?? false
        voiceCallEnabled = c.decodeLossyBoolIfPresent(forKey: .voiceCallEnabled)
        videoCallEnabled = c.decodeLossyBoolIfPresent(forKey: .videoCallEnabled)
        capabilitiesVersion = try c.decodeIfPresent(String.self, forKey: .capabilitiesVersion) ?? ""
        mediaPlaneConfigured = c.decodeLossyBoolIfPresent(forKey: .mediaPlaneConfigured) ?? false
        iceServersConfigured = c.decodeLossyBoolIfPresent(forKey: .iceServersConfigured) ?? mediaPlaneConfigured
        callTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .callTimeoutSeconds)
        self.init(iceTransportPolicyVersion: iceTransportPolicyVersion, callTypes: callTypes, videoSupported: videoSupported, voiceCallEnabled: voiceCallEnabled, videoCallEnabled: videoCallEnabled, capabilitiesVersion: capabilitiesVersion, mediaPlaneConfigured: mediaPlaneConfigured, iceServersConfigured: iceServersConfigured, callTimeoutSeconds: callTimeoutSeconds)
    }
}

typealias RTCDeviceCapabilities = IM4Data.RTCDeviceCapabilities

extension RTCDeviceCapabilities {
    var requestBody: [String: Any] {
        [
            "version": version,
            "audio": audio,
            "video": video,
            "camera_available": cameraAvailable
        ]
    }
}

typealias RemoteRTCCallsData = IM4Data.RemoteRTCCallsData

typealias RemoteRTCDevice = IM4Data.RemoteRTCDevice

typealias RemoteRTCRoomParticipant = IM4Data.RemoteRTCRoomParticipant

typealias RemoteRTCCallResponse = IM4Data.RemoteRTCCallResponse

extension RemoteRTCCallResponse: @retroactive Decodable {
    // Bound to the actual scoped provider observation used by this create request.

    enum CodingKeys: String, CodingKey {
        case call
        case rtcToken = "rtc_token"
    }

    public init(from decoder: Decoder) throws {
        var requiresAcceptedDeviceBeforeJoin: Bool = false
        let call: RemoteRTCCall
        let rtcToken: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        call = try c.decodeIfPresent(RemoteRTCCall.self, forKey: .call) ?? RemoteRTCCall()
        rtcToken = try c.decodeIfPresent(String.self, forKey: .rtcToken) ?? ""
        guard RTCCallRecordRedialFreshnessContext.acceptsCreatedCall(call) else {
            throw DecodingError.dataCorruptedError(
                forKey: .call,
                in: c,
                debugDescription: "Redial create response did not contain a fresh call identity"
            )
        }
        self.init(requiresAcceptedDeviceBeforeJoin: requiresAcceptedDeviceBeforeJoin, call: call, rtcToken: rtcToken)
    }
}

typealias RemoteRTCParticipantProfile = IM4Data.RemoteRTCParticipantProfile

extension RemoteRTCParticipantProfile {
    static func from(dictionary: [String: Any]?) -> RemoteRTCParticipantProfile? {
        guard let dictionary else { return nil }
        let profile = RemoteRTCParticipantProfile(
            uid: firstString(dictionary, keys: ["uid", "im_uid", "imUID", "id"]),
            userID: firstString(dictionary, keys: ["user_id", "userID", "userId"]),
            displayName: firstString(dictionary, keys: ["display_name", "displayName", "nickname", "name", "username"]),
            avatar: firstString(dictionary, keys: ["avatar", "avatar_url", "avatarURL", "avatarUrl"]),
            avatarVersion: firstString(dictionary, keys: ["avatar_version", "avatarVersion", "version"]),
            avatarUpdatedAt: firstString(dictionary, keys: ["avatar_updated_at", "avatarUpdatedAt", "updated_at", "updatedAt"])
        )
        return profile.isEmpty ? nil : profile
    }

    var isEmpty: Bool {
        [uid, userID, displayName, avatar, avatarVersion, avatarUpdatedAt].allSatisfy { $0.isEmpty }
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                return stringValue(value)
            }
        }
        return ""
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

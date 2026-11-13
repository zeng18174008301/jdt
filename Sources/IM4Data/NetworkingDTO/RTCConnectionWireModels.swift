// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteRTCProvider: Sendable {
    public let iceTransportPolicyVersion: Int?
    public let callTypes: [String]
    public let videoSupported: Bool
    public let voiceCallEnabled: Bool?
    public let videoCallEnabled: Bool?
    public let capabilitiesVersion: String
    public let mediaPlaneConfigured: Bool
    public let iceServersConfigured: Bool
    public let callTimeoutSeconds: Int?

    public init(iceTransportPolicyVersion: Int?, callTypes: [String], videoSupported: Bool, voiceCallEnabled: Bool?, videoCallEnabled: Bool?, capabilitiesVersion: String, mediaPlaneConfigured: Bool, iceServersConfigured: Bool, callTimeoutSeconds: Int?) {
        self.iceTransportPolicyVersion = iceTransportPolicyVersion
        self.callTypes = callTypes
        self.videoSupported = videoSupported
        self.voiceCallEnabled = voiceCallEnabled
        self.videoCallEnabled = videoCallEnabled
        self.capabilitiesVersion = capabilitiesVersion
        self.mediaPlaneConfigured = mediaPlaneConfigured
        self.iceServersConfigured = iceServersConfigured
        self.callTimeoutSeconds = callTimeoutSeconds
    }
}

public struct RTCDeviceCapabilities: Codable, Sendable, Equatable {
    public static let protocolVersion = "video-call-v1"

    public let version: String
    public let audio: Bool
    public let video: Bool
    public let cameraAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case audio
        case video
        case cameraAvailable = "camera_available"
    }

    public init(
        version: String = Self.protocolVersion,
        audio: Bool = true,
        video: Bool,
        cameraAvailable: Bool
    ) {
        self.version = version
        self.audio = audio
        self.video = video
        self.cameraAvailable = cameraAvailable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older/voice-only RTC responses legitimately omit the version and
        // capability booleans through Go's `omitempty`.  A missing optional
        // capability must not turn a successful HTTP 201 create response into
        // a transport error (whose localized phrase is just "created").
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        audio = c.decodeLossyBoolIfPresent(forKey: .audio) ?? false
        video = c.decodeLossyBoolIfPresent(forKey: .video) ?? false
        cameraAvailable = c.decodeLossyBoolIfPresent(forKey: .cameraAvailable) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(audio, forKey: .audio)
        try c.encode(video, forKey: .video)
        try c.encode(cameraAvailable, forKey: .cameraAvailable)
    }


}

public struct RemoteRTCCallsData: Decodable, Sendable {
    public let calls: [RemoteRTCCall]

    enum CodingKeys: String, CodingKey {
        case calls
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent([RemoteRTCCall].self, forKey: .calls)
            ?? c.decodeIfPresent([RemoteRTCCall].self, forKey: .items)
            ?? []
    }
}

public struct RemoteRTCDevice: Codable, Sendable, Equatable {
    public let uid: String
    public let deviceID: String
    public let deviceType: String
    public let appID: String

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case uid
        case deviceID = "device_id"
        case deviceType = "device_type"
    }

    public init(uid: String = "", deviceID: String = "", deviceType: String = "", appID: String = "") {
        self.uid = uid
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.appID = appID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType) ?? ""
    }
}

public struct RemoteRTCRoomParticipant: Codable, Sendable, Equatable {
    public let uid: String
    public let deviceID: String
    public let deviceType: String
    public let role: String
    public let joinedAt: String

    enum CodingKeys: String, CodingKey {
        case uid
        case imUID = "im_uid"
        case userID = "user_id"
        case deviceID = "device_id"
        case deviceId = "deviceId"
        case id
        case deviceType = "device_type"
        case deviceTypeCamel = "deviceType"
        case appID = "app_id"
        case role
        case status
        case joinedAt = "joined_at"
        case joinedAtCamel = "joinedAt"
    }

    public init(uid: String = "", deviceID: String = "", deviceType: String = "", role: String = "", joinedAt: String = "") {
        self.uid = uid
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.role = role
        self.joinedAt = joinedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid)
            ?? c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .userID)
            ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
            ?? c.decodeIfPresent(String.self, forKey: .deviceId)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
            ?? c.decodeIfPresent(String.self, forKey: .deviceTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .appID)
            ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role)
            ?? c.decodeIfPresent(String.self, forKey: .status)
            ?? ""
        joinedAt = try c.decodeIfPresent(String.self, forKey: .joinedAt)
            ?? c.decodeIfPresent(String.self, forKey: .joinedAtCamel)
            ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(deviceType, forKey: .deviceType)
        try c.encode(role, forKey: .role)
        try c.encode(joinedAt, forKey: .joinedAt)
    }
}

public struct RemoteRTCCallResponse: Sendable {
    public var requiresAcceptedDeviceBeforeJoin = false
    public let call: RemoteRTCCall
    public let rtcToken: String

    public init(requiresAcceptedDeviceBeforeJoin: Bool = false, call: RemoteRTCCall, rtcToken: String) {
        self.requiresAcceptedDeviceBeforeJoin = requiresAcceptedDeviceBeforeJoin
        self.call = call
        self.rtcToken = rtcToken
    }
}

public struct RemoteRTCParticipantProfile: Decodable, Equatable, Sendable {
    public let uid: String
    public let userID: String
    public let displayName: String
    public let avatar: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case uid
        case imUID = "im_uid"
        case userID = "user_id"
        case userIDCamel = "userId"
        case id
        case displayName = "display_name"
        case nickname
        case name
        case username
        case avatar
        case avatarURL = "avatar_url"
        case avatarURLCamel = "avatarUrl"
        case avatarVersion = "avatar_version"
        case avatarVersionCamel = "avatarVersion"
        case version
        case avatarUpdatedAt = "avatar_updated_at"
        case avatarUpdatedAtCamel = "avatarUpdatedAt"
        case updatedAt = "updated_at"
        case departmentName = "department_name"
        case departmentNameCamel = "departmentName"
        case departmentPath = "department_path"
        case departmentPathCamel = "departmentPath"
        case departmentPathNames = "department_path_names"
        case departmentPathNamesCamel = "departmentPathNames"
    }

    public init(
        uid: String = "",
        userID: String = "",
        displayName: String = "",
        avatar: String = "",
        avatarVersion: String = "",
        avatarUpdatedAt: String = ""
    ) {
        self.uid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatar = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarVersion = avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.avatarUpdatedAt = avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uid: try c.decodeIfPresent(String.self, forKey: .uid)
                ?? c.decodeIfPresent(String.self, forKey: .imUID)
                ?? c.decodeIfPresent(String.self, forKey: .id)
                ?? "",
            userID: try c.decodeIfPresent(String.self, forKey: .userID)
                ?? c.decodeIfPresent(String.self, forKey: .userIDCamel)
                ?? "",
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName)
                ?? c.decodeIfPresent(String.self, forKey: .nickname)
                ?? c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .username)
                ?? "",
            avatar: try c.decodeIfPresent(String.self, forKey: .avatar)
                ?? c.decodeIfPresent(String.self, forKey: .avatarURL)
                ?? c.decodeIfPresent(String.self, forKey: .avatarURLCamel)
                ?? "",
            avatarVersion: try c.decodeIfPresent(String.self, forKey: .avatarVersion)
                ?? c.decodeIfPresent(String.self, forKey: .avatarVersionCamel)
                ?? c.decodeIfPresent(String.self, forKey: .version)
                ?? "",
            avatarUpdatedAt: try c.decodeIfPresent(String.self, forKey: .avatarUpdatedAt)
                ?? c.decodeIfPresent(String.self, forKey: .avatarUpdatedAtCamel)
                ?? c.decodeIfPresent(String.self, forKey: .updatedAt)
                ?? ""
        )
    }








}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

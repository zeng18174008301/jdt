// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteRTCCall: Decodable, Sendable {
    public let id: String
    public let status: String
    public let roomID: String
    public let rtcToken: String
    public let callerUID: String
    public let calleeUID: String
    public let channelID: String
    public let channelType: String
    public let callType: String
    public let requestedMediaMode: String
    public let mediaMode: String
    public let peerCapabilityStatus: String
    public let callerCapabilities: RTCDeviceCapabilities?
    public let callerDevice: RemoteRTCDevice?
    public let calleeDevice: RemoteRTCDevice?
    public let acceptedDevice: RemoteRTCDevice?
    public let callerProfile: RemoteRTCParticipantProfile?
    public let calleeProfile: RemoteRTCParticipantProfile?
    public let callerName: String
    public let calleeName: String
    public let callerAvatarURL: String
    public let callerAvatarVersion: String
    public let callerAvatarUpdatedAt: String
    public let calleeAvatarURL: String
    public let calleeAvatarVersion: String
    public let calleeAvatarUpdatedAt: String
    public let createdAt: String
    public let updatedAt: String
    public let startedAt: String
    public let acceptedAt: String
    public let endedAt: String
    public let endReason: String
    public let stateVersion: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case callID = "call_id"
        case status
        case roomID = "room_id"
        case rtcToken = "rtc_token"
        case callerUID = "caller_uid"
        case calleeUID = "callee_uid"
        case targetUID = "target_uid"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case callType = "call_type"
        case requestedMediaMode = "requested_media_mode"
        case mediaMode = "media_mode"
        case peerCapabilityStatus = "peer_capability_status"
        case callerCapabilities = "caller_capabilities"
        case callerDevice = "caller_device"
        case calleeDevice = "callee_device"
        case acceptedDevice = "accepted_device"
        case callerProfile = "caller_profile"
        case callerProfileCamel = "callerProfile"
        case caller
        case fromProfile = "from_profile"
        case calleeProfile = "callee_profile"
        case calleeProfileCamel = "calleeProfile"
        case callee
        case targetProfile = "target_profile"
        case callerName = "caller_name"
        case callerNameCamel = "callerName"
        case fromName = "from_name"
        case calleeName = "callee_name"
        case calleeNameCamel = "calleeName"
        case targetName = "target_name"
        case callerAvatar = "caller_avatar"
        case callerAvatarURL = "caller_avatar_url"
        case callerAvatarURLCamel = "callerAvatarUrl"
        case callerAvatarVersion = "caller_avatar_version"
        case callerAvatarVersionCamel = "callerAvatarVersion"
        case callerAvatarUpdatedAt = "caller_avatar_updated_at"
        case callerAvatarUpdatedAtCamel = "callerAvatarUpdatedAt"
        case calleeAvatar = "callee_avatar"
        case calleeAvatarURL = "callee_avatar_url"
        case calleeAvatarURLCamel = "calleeAvatarUrl"
        case targetAvatar = "target_avatar"
        case targetAvatarURL = "target_avatar_url"
        case calleeAvatarVersion = "callee_avatar_version"
        case calleeAvatarVersionCamel = "calleeAvatarVersion"
        case targetAvatarVersion = "target_avatar_version"
        case calleeAvatarUpdatedAt = "callee_avatar_updated_at"
        case calleeAvatarUpdatedAtCamel = "calleeAvatarUpdatedAt"
        case targetAvatarUpdatedAt = "target_avatar_updated_at"
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case startedAt = "started_at"
        case startedAtCamel = "startedAt"
        case acceptedAt = "accepted_at"
        case acceptedAtCamel = "acceptedAt"
        case endedAt = "ended_at"
        case endedAtCamel = "endedAt"
        case endReason = "end_reason"
        case endReasonCamel = "endReason"
        case stateVersion = "state_version"
        case stateVersionCamel = "stateVersion"
    }

    public init(
        id: String = "",
        status: String = "",
        roomID: String = "",
        rtcToken: String = "",
        callerUID: String = "",
        calleeUID: String = "",
        channelID: String = "",
        channelType: String = "",
        callType: String = "",
        requestedMediaMode: String = "",
        mediaMode: String = "",
        peerCapabilityStatus: String = "",
        callerCapabilities: RTCDeviceCapabilities? = nil,
        callerDevice: RemoteRTCDevice? = nil,
        calleeDevice: RemoteRTCDevice? = nil,
        acceptedDevice: RemoteRTCDevice? = nil,
        callerProfile: RemoteRTCParticipantProfile? = nil,
        calleeProfile: RemoteRTCParticipantProfile? = nil,
        callerName: String = "",
        calleeName: String = "",
        callerAvatarURL: String = "",
        callerAvatarVersion: String = "",
        callerAvatarUpdatedAt: String = "",
        calleeAvatarURL: String = "",
        calleeAvatarVersion: String = "",
        calleeAvatarUpdatedAt: String = "",
        createdAt: String = "",
        updatedAt: String = "",
        startedAt: String = "",
        acceptedAt: String = "",
        endedAt: String = "",
        endReason: String = "",
        stateVersion: Int64 = 0
    ) {
        self.id = id
        self.status = status
        self.roomID = roomID
        self.rtcToken = rtcToken
        self.callerUID = callerUID
        self.calleeUID = calleeUID
        self.channelID = channelID
        self.channelType = channelType
        self.callType = callType
        self.requestedMediaMode = requestedMediaMode
        self.mediaMode = mediaMode
        self.peerCapabilityStatus = peerCapabilityStatus
        self.callerCapabilities = callerCapabilities
        self.callerDevice = callerDevice
        self.calleeDevice = calleeDevice
        self.acceptedDevice = acceptedDevice
        self.callerProfile = callerProfile
        self.calleeProfile = calleeProfile
        self.callerName = callerName
        self.calleeName = calleeName
        self.callerAvatarURL = callerAvatarURL
        self.callerAvatarVersion = callerAvatarVersion
        self.callerAvatarUpdatedAt = callerAvatarUpdatedAt
        self.calleeAvatarURL = calleeAvatarURL
        self.calleeAvatarVersion = calleeAvatarVersion
        self.calleeAvatarUpdatedAt = calleeAvatarUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.acceptedAt = acceptedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.stateVersion = stateVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .callID)
            ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID) ?? ""
        rtcToken = try c.decodeIfPresent(String.self, forKey: .rtcToken) ?? ""
        callerUID = try c.decodeIfPresent(String.self, forKey: .callerUID) ?? ""
        calleeUID = try c.decodeIfPresent(String.self, forKey: .calleeUID)
            ?? c.decodeIfPresent(String.self, forKey: .targetUID)
            ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        callType = try c.decodeIfPresent(String.self, forKey: .callType) ?? ""
        requestedMediaMode = try c.decodeIfPresent(String.self, forKey: .requestedMediaMode) ?? callType
        mediaMode = try c.decodeIfPresent(String.self, forKey: .mediaMode) ?? callType
        peerCapabilityStatus = try c.decodeIfPresent(String.self, forKey: .peerCapabilityStatus) ?? "unknown"
        callerCapabilities = try c.decodeIfPresent(RTCDeviceCapabilities.self, forKey: .callerCapabilities)
        callerDevice = try c.decodeIfPresent(RemoteRTCDevice.self, forKey: .callerDevice)
        calleeDevice = try c.decodeIfPresent(RemoteRTCDevice.self, forKey: .calleeDevice)
        acceptedDevice = try c.decodeIfPresent(RemoteRTCDevice.self, forKey: .acceptedDevice)
        callerProfile = try c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .callerProfile)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .callerProfileCamel)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .caller)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .fromProfile)
        calleeProfile = try c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .calleeProfile)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .calleeProfileCamel)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .callee)
            ?? c.decodeIfPresent(RemoteRTCParticipantProfile.self, forKey: .targetProfile)
        callerName = try c.decodeIfPresent(String.self, forKey: .callerName)
            ?? c.decodeIfPresent(String.self, forKey: .callerNameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .fromName)
            ?? callerProfile?.displayName
            ?? ""
        calleeName = try c.decodeIfPresent(String.self, forKey: .calleeName)
            ?? c.decodeIfPresent(String.self, forKey: .calleeNameCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetName)
            ?? calleeProfile?.displayName
            ?? ""
        callerAvatarURL = try c.decodeIfPresent(String.self, forKey: .callerAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarURLCamel)
            ?? callerProfile?.avatar
            ?? ""
        callerAvatarVersion = try c.decodeIfPresent(String.self, forKey: .callerAvatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarVersionCamel)
            ?? callerProfile?.avatarVersion
            ?? ""
        callerAvatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .callerAvatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .callerAvatarUpdatedAtCamel)
            ?? callerProfile?.avatarUpdatedAt
            ?? ""
        calleeAvatarURL = try c.decodeIfPresent(String.self, forKey: .calleeAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarURL)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarURLCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatar)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarURL)
            ?? calleeProfile?.avatar
            ?? ""
        calleeAvatarVersion = try c.decodeIfPresent(String.self, forKey: .calleeAvatarVersion)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarVersionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarVersion)
            ?? calleeProfile?.avatarVersion
            ?? ""
        calleeAvatarUpdatedAt = try c.decodeIfPresent(String.self, forKey: .calleeAvatarUpdatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .calleeAvatarUpdatedAtCamel)
            ?? c.decodeIfPresent(String.self, forKey: .targetAvatarUpdatedAt)
            ?? calleeProfile?.avatarUpdatedAt
            ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
            ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel)
            ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
            ?? c.decodeIfPresent(String.self, forKey: .startedAtCamel)
            ?? ""
        acceptedAt = try c.decodeIfPresent(String.self, forKey: .acceptedAt)
            ?? c.decodeIfPresent(String.self, forKey: .acceptedAtCamel)
            ?? ""
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
            ?? c.decodeIfPresent(String.self, forKey: .endedAtCamel)
            ?? ""
        endReason = try c.decodeIfPresent(String.self, forKey: .endReason)
            ?? c.decodeIfPresent(String.self, forKey: .endReasonCamel)
            ?? ""
        stateVersion = c.decodeLossyInt64IfPresent(forKey: .stateVersion)
            ?? c.decodeLossyInt64IfPresent(forKey: .stateVersionCamel)
            ?? 0
    }
}

public struct RemoteRTCRoomJoinData: Sendable {
    public let roomID: String
    public let rtcToken: String
    public let media: RemoteRTCMedia
    public let selfParticipant: RemoteRTCRoomParticipant?
    public let peerParticipant: RemoteRTCRoomParticipant?
    public let participants: [RemoteRTCRoomParticipant]

    public init(
        roomID: String = "",
        rtcToken: String = "",
        media: RemoteRTCMedia = RemoteRTCMedia(),
        selfParticipant: RemoteRTCRoomParticipant? = nil,
        peerParticipant: RemoteRTCRoomParticipant? = nil,
        participants: [RemoteRTCRoomParticipant] = []
    ) {
        self.roomID = roomID
        self.rtcToken = rtcToken
        self.media = media
        self.selfParticipant = selfParticipant
        self.peerParticipant = peerParticipant
        self.participants = participants
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

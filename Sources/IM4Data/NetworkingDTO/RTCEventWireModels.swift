// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Domain

public struct RemoteRTCCallEventsData: Decodable, Sendable {
    public let events: [RemoteRTCCallEvent]

    enum CodingKeys: String, CodingKey {
        case events
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([RemoteRTCCallEvent].self, forKey: .events)
            ?? c.decodeIfPresent([RemoteRTCCallEvent].self, forKey: .items)
            ?? []
    }
}

public struct RemoteRTCCallEvent: Decodable, Sendable {
    public let id: String
    public let notificationID: String
    public let type: String
    public let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id
        case notificationID = "notification_id"
        case type
        case event
        case eventType = "event_type"
        case callID = "call_id"
        case status
        case callerUID = "caller_uid"
        case calleeUID = "callee_uid"
        case targetUID = "target_uid"
        case roomID = "room_id"
        case channelID = "channel_id"
        case callType = "call_type"
        case requestedMediaMode = "requested_media_mode"
        case mediaMode = "media_mode"
        case stateVersion = "state_version"
        case callerDevice = "caller_device"
        case calleeDevice = "callee_device"
        case acceptedDevice = "accepted_device"
        case callerDeviceID = "caller_device_id"
        case calleeDeviceID = "callee_device_id"
        case acceptedDeviceID = "accepted_device_id"
        case call
        case payload
        case rtcCall = "rtc_call"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        notificationID = try c.decodeIfPresent(String.self, forKey: .notificationID) ?? ""
        let decodedType = try c.decodeIfPresent(String.self, forKey: .type)
            ?? c.decodeIfPresent(String.self, forKey: .event)
            ?? c.decodeIfPresent(String.self, forKey: .eventType)
            ?? ""
        let decodedStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        type = decodedType.isEmpty && !decodedStatus.isEmpty ? "rtc.call.\(decodedStatus)" : decodedType
        var decodedPayload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload)
            ?? c.decodeIfPresent([String: JSONValue].self, forKey: .rtcCall)
            ?? [:]
        if decodedPayload["call"] == nil,
           let nestedCall = try c.decodeIfPresent([String: JSONValue].self, forKey: .call),
           !nestedCall.isEmpty {
            decodedPayload["call"] = .object(nestedCall)
        }
        func merge(_ value: String?, key: String) {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  decodedPayload[key] == nil else { return }
            decodedPayload[key] = .string(value)
        }
        merge(id, key: "event_id")
        merge(type, key: "event")
        merge(try c.decodeIfPresent(String.self, forKey: .callID), key: "call_id")
        merge(decodedStatus, key: "status")
        merge(try c.decodeIfPresent(String.self, forKey: .callerUID), key: "caller_uid")
        merge(try c.decodeIfPresent(String.self, forKey: .calleeUID), key: "callee_uid")
        merge(try c.decodeIfPresent(String.self, forKey: .targetUID), key: "target_uid")
        merge(try c.decodeIfPresent(String.self, forKey: .roomID), key: "room_id")
        merge(try c.decodeIfPresent(String.self, forKey: .channelID), key: "channel_id")
        func mergeValue(_ codingKey: CodingKeys, key: String) throws {
            guard decodedPayload[key] == nil,
                  let value = try c.decodeIfPresent(JSONValue.self, forKey: codingKey) else { return }
            decodedPayload[key] = value
        }
        try mergeValue(.callType, key: "call_type")
        try mergeValue(.requestedMediaMode, key: "requested_media_mode")
        try mergeValue(.mediaMode, key: "media_mode")
        try mergeValue(.stateVersion, key: "state_version")
        try mergeValue(.callerDevice, key: "caller_device")
        try mergeValue(.calleeDevice, key: "callee_device")
        try mergeValue(.acceptedDevice, key: "accepted_device")
        try mergeValue(.callerDeviceID, key: "caller_device_id")
        try mergeValue(.calleeDeviceID, key: "callee_device_id")
        try mergeValue(.acceptedDeviceID, key: "accepted_device_id")
        payload = decodedPayload
    }
}

public struct RTCVoIPPushPayload: Equatable, Sendable {
    public let kind: String
    public let event: String
    public let callID: String
    public let roomID: String
    public let tenantID: String
    public let callerUID: String
    public let calleeUID: String
    public let callerName: String
    public let calleeName: String
    public let callerAvatarURL: String
    public let callerAvatarVersion: String
    public let callerAvatarUpdatedAt: String
    public let calleeAvatarURL: String
    public let calleeAvatarVersion: String
    public let calleeAvatarUpdatedAt: String
    public let callerProfile: RemoteRTCParticipantProfile?
    public let calleeProfile: RemoteRTCParticipantProfile?
    public let callType: String
    public let provider: String
    public let issuedAt: String
    public let expiresAt: String

    public init(kind: String, event: String, callID: String, roomID: String, tenantID: String, callerUID: String, calleeUID: String, callerName: String, calleeName: String, callerAvatarURL: String, callerAvatarVersion: String, callerAvatarUpdatedAt: String, calleeAvatarURL: String, calleeAvatarVersion: String, calleeAvatarUpdatedAt: String, callerProfile: RemoteRTCParticipantProfile?, calleeProfile: RemoteRTCParticipantProfile?, callType: String, provider: String, issuedAt: String, expiresAt: String) {
        self.kind = kind
        self.event = event
        self.callID = callID
        self.roomID = roomID
        self.tenantID = tenantID
        self.callerUID = callerUID
        self.calleeUID = calleeUID
        self.callerName = callerName
        self.calleeName = calleeName
        self.callerAvatarURL = callerAvatarURL
        self.callerAvatarVersion = callerAvatarVersion
        self.callerAvatarUpdatedAt = callerAvatarUpdatedAt
        self.calleeAvatarURL = calleeAvatarURL
        self.calleeAvatarVersion = calleeAvatarVersion
        self.calleeAvatarUpdatedAt = calleeAvatarUpdatedAt
        self.callerProfile = callerProfile
        self.calleeProfile = calleeProfile
        self.callType = callType
        self.provider = provider
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

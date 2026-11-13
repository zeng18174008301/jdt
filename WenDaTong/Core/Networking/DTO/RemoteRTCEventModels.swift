// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

typealias RTCVoiceMediaState = IM4Domain.RTCVoiceMediaState

extension RTCVoiceMediaState {
    var qualifiesForConnectedAt: Bool {
        self == .connected
    }
}

typealias RTCVoiceMediaEvent = IM4Domain.RTCVoiceMediaEvent

extension RTCVoiceMediaEvent {
    var mediaState: RTCVoiceMediaState {
        switch self {
        case .callAccepted, .roomJoined, .localTrackReady:
            return .preparing
        case .remoteAudioTrackReady, .remoteAudioRTPReady:
            return .connecting
        case .localDescriptionSet, .remoteDescriptionSet:
            return .signaling
        case .iceChecking:
            return .connecting
        case .iceConnected, .iceCompleted, .peerConnectionConnected, .connectionRecovered:
            return .connecting
        case .iceDisconnected:
            return .unstable
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
        case .iceFailed, .mediaStartFailed, .recoveryExhausted:
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return .failed
        case .closed:
            return .closed
        }
    }

    var qualifiesForConnectedAt: Bool {
        mediaState.qualifiesForConnectedAt
    }
}

typealias RemoteRTCCallEventsData = IM4Data.RemoteRTCCallEventsData

typealias RemoteRTCCallEvent = IM4Data.RemoteRTCCallEvent

typealias RTCVoIPPushPayload = IM4Data.RTCVoIPPushPayload

extension RTCVoIPPushPayload {

    init?(_ userInfo: [AnyHashable: Any]) {
        var dictionary: [String: Any] = [:]
        userInfo.forEach { key, value in
            dictionary[String(describing: key)] = value
        }
        self.init(dictionary: dictionary)
    }

    init?(dictionary: [String: Any]) {
        let kind: String
        let event: String
        let callID: String
        let roomID: String
        let tenantID: String
        let callerUID: String
        let calleeUID: String
        let callerName: String
        let calleeName: String
        let callerAvatarURL: String
        let callerAvatarVersion: String
        let callerAvatarUpdatedAt: String
        let calleeAvatarURL: String
        let calleeAvatarVersion: String
        let calleeAvatarUpdatedAt: String
        let callerProfile: RemoteRTCParticipantProfile?
        let calleeProfile: RemoteRTCParticipantProfile?
        let callType: String
        let provider: String
        let issuedAt: String
        let expiresAt: String
        let dictionary = Self.normalizedVoIPPayloadDictionary(dictionary)
        let decodedKind = Self.firstString(dictionary, keys: ["kind", "type"]).lowercased()
        guard decodedKind == "rtc_call" else { return nil }
        let decodedCallID = Self.firstString(dictionary, keys: ["call_id", "callID", "id"])
        guard !decodedCallID.isEmpty else { return nil }

        kind = decodedKind
        event = Self.firstString(dictionary, keys: ["event", "status"]).lowercased()
        callID = decodedCallID
        roomID = Self.firstString(dictionary, keys: ["room_id", "roomID"])
        tenantID = Self.firstString(dictionary, keys: ["tenant_id", "tenantID"])
        callerUID = Self.firstString(dictionary, keys: ["caller_uid", "callerUID", "from_uid", "fromUID"])
        calleeUID = Self.firstString(dictionary, keys: ["callee_uid", "calleeUID", "target_uid", "targetUID"])
        callerProfile = RemoteRTCParticipantProfile.from(
            dictionary: Self.dictionaryValue(dictionary["caller_profile"])
                ?? Self.dictionaryValue(dictionary["callerProfile"])
                ?? Self.dictionaryValue(dictionary["caller"])
                ?? Self.dictionaryValue(dictionary["from_profile"])
        )
        calleeProfile = RemoteRTCParticipantProfile.from(
            dictionary: Self.dictionaryValue(dictionary["callee_profile"])
                ?? Self.dictionaryValue(dictionary["calleeProfile"])
                ?? Self.dictionaryValue(dictionary["callee"])
                ?? Self.dictionaryValue(dictionary["target_profile"])
        )
        callerName = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_name", "callerName", "from_name", "fromName"]), callerProfile?.displayName ?? "")
        calleeName = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_name", "calleeName", "target_name", "targetName"]), calleeProfile?.displayName ?? "")
        callerAvatarURL = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_avatar", "caller_avatar_url", "callerAvatar", "callerAvatarUrl", "from_avatar", "fromAvatar"]), callerProfile?.avatar ?? "")
        callerAvatarVersion = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_avatar_version", "callerAvatarVersion", "from_avatar_version", "fromAvatarVersion"]), callerProfile?.avatarVersion ?? "")
        callerAvatarUpdatedAt = Self.fallbackString(Self.firstString(dictionary, keys: ["caller_avatar_updated_at", "callerAvatarUpdatedAt", "from_avatar_updated_at", "fromAvatarUpdatedAt"]), callerProfile?.avatarUpdatedAt ?? "")
        calleeAvatarURL = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_avatar", "callee_avatar_url", "calleeAvatar", "calleeAvatarUrl", "target_avatar", "target_avatar_url", "targetAvatar", "targetAvatarUrl"]), calleeProfile?.avatar ?? "")
        calleeAvatarVersion = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_avatar_version", "calleeAvatarVersion", "target_avatar_version", "targetAvatarVersion"]), calleeProfile?.avatarVersion ?? "")
        calleeAvatarUpdatedAt = Self.fallbackString(Self.firstString(dictionary, keys: ["callee_avatar_updated_at", "calleeAvatarUpdatedAt", "target_avatar_updated_at", "targetAvatarUpdatedAt"]), calleeProfile?.avatarUpdatedAt ?? "")
        callType = Self.firstString(dictionary, keys: ["call_type", "callType"]).lowercased()
        provider = Self.firstString(dictionary, keys: ["provider"]).lowercased()
        issuedAt = Self.firstString(dictionary, keys: ["issued_at", "issuedAt"])
        expiresAt = Self.firstString(dictionary, keys: ["expires_at", "expiresAt"])
        self.init(kind: kind, event: event, callID: callID, roomID: roomID, tenantID: tenantID, callerUID: callerUID, calleeUID: calleeUID, callerName: callerName, calleeName: calleeName, callerAvatarURL: callerAvatarURL, callerAvatarVersion: callerAvatarVersion, callerAvatarUpdatedAt: callerAvatarUpdatedAt, calleeAvatarURL: calleeAvatarURL, calleeAvatarVersion: calleeAvatarVersion, calleeAvatarUpdatedAt: calleeAvatarUpdatedAt, callerProfile: callerProfile, calleeProfile: calleeProfile, callType: callType, provider: provider, issuedAt: issuedAt, expiresAt: expiresAt)
    }

    var isRinging: Bool {
        event == "ringing"
    }

    var isPushKitEligibleRinging: Bool {
        kind == "rtc_call" && event == "ringing" && !callID.isEmpty
    }

    func deliveryFreshness(now: Date = Date()) -> RTCVoIPPushDeliveryFreshness {
        let formatter = ISO8601DateFormatter()
        guard !expiresAt.isEmpty, let expiry = formatter.date(from: expiresAt) else {
            return .unknown
        }
        if !issuedAt.isEmpty,
           let issued = formatter.date(from: issuedAt),
           expiry <= issued {
            return .invalidWindow
        }
        return expiry <= now ? .expired : .fresh
    }

    var isTerminal: Bool {
        ["cancel", "canceled", "ended", "timeout", "timed_out", "answered_elsewhere"].contains(event)
    }

    var normalizedTerminalEvent: String {
        switch event {
        case "cancel":
            return "canceled"
        case "timeout":
            return "timed_out"
        default:
            return event
        }
    }

    var deterministicUUID: UUID {
        Self.deterministicUUIDForCallKit(callID)
    }

    static func deterministicUUIDForCallKit(_ value: String) -> UUID {
        deterministicUUID(for: value)
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                return stringValue(value)
            }
        }
        return ""
    }

    private static func fallbackString(_ value: String, _ fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    private static func normalizedVoIPPayloadDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        guard var nested = dictionaryValue(dictionary["rtc_call"]) ?? dictionaryValue(dictionary["rtcCall"]) else {
            return dictionary
        }
        for (key, value) in dictionary where key != "aps" && key != "rtc_call" && key != "rtcCall" {
            if nested[key] == nil {
                nested[key] = value
            }
        }
        return nested
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            dictionary.forEach { key, value in
                out[String(describing: key)] = value
            }
            return out
        }
        return nil
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

    private static func deterministicUUID(for value: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            h1 ^= UInt64(byte)
            h1 = h1 &* 0x100000001b3
            h2 ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            h2 = h2 &* 0x100000001b3
        }
        var bytes = withUnsafeBytes(of: h1.bigEndian, Array.init)
        bytes.append(contentsOf: withUnsafeBytes(of: h2.bigEndian, Array.init))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuidString = bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress!).uuidString
        }
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

typealias RTCVoIPPushDeliveryFreshness = IM4Domain.RTCVoIPPushDeliveryFreshness
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

typealias RemoteRTCCall = IM4Data.RemoteRTCCall

typealias RemoteRTCRoomJoinData = IM4Data.RemoteRTCRoomJoinData

extension RemoteRTCRoomJoinData: @retroactive Decodable {

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case rtcToken = "rtc_token"
        case media
        case participant
        case selfParticipant = "self_participant"
        case peerParticipant = "peer_participant"
        case participants
    }

    enum MediaCodingKeys: String, CodingKey {
        case roomID = "room_id"
        case rtcToken = "rtc_token"
    }



    public init(from decoder: Decoder) throws {
        let roomID: String
        let rtcToken: String
        let media: RemoteRTCMedia
        let selfParticipant: RemoteRTCRoomParticipant?
        let peerParticipant: RemoteRTCRoomParticipant?
        let participants: [RemoteRTCRoomParticipant]
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mediaContainer = try? c.nestedContainer(keyedBy: MediaCodingKeys.self, forKey: .media)
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID)
            ?? mediaContainer?.decodeIfPresent(String.self, forKey: .roomID)
            ?? ""
        rtcToken = try c.decodeIfPresent(String.self, forKey: .rtcToken)
            ?? mediaContainer?.decodeIfPresent(String.self, forKey: .rtcToken)
            ?? ""
        media = try c.decodeIfPresent(RemoteRTCMedia.self, forKey: .media) ?? RemoteRTCMedia()
        let legacyParticipant = try c.decodeIfPresent(RemoteRTCRoomParticipant.self, forKey: .participant)
        selfParticipant = try c.decodeIfPresent(RemoteRTCRoomParticipant.self, forKey: .selfParticipant)
            ?? legacyParticipant
        peerParticipant = try c.decodeIfPresent(RemoteRTCRoomParticipant.self, forKey: .peerParticipant)
        let decodedParticipants = try c.decodeIfPresent([RemoteRTCRoomParticipant].self, forKey: .participants) ?? []
        if decodedParticipants.isEmpty, let legacyParticipant {
            participants = [legacyParticipant]
        } else {
            participants = decodedParticipants
        }
        self.init(roomID: roomID, rtcToken: rtcToken, media: media, selfParticipant: selfParticipant, peerParticipant: peerParticipant, participants: participants)
    }
}
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

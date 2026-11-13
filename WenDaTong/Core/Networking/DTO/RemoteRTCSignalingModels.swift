// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_BEGIN
import Foundation
import IM4Data
import IM4Domain

typealias RemoteRTCSignalKind = IM4Domain.RemoteRTCSignalKind

typealias RemoteRTCSignalEnvelope = IM4Data.RemoteRTCSignalEnvelope

typealias RemoteRTCSignalItemsData = IM4Data.RemoteRTCSignalItemsData

typealias RemoteRTCSignalItem = IM4Data.RemoteRTCSignalItem

typealias RemoteRTCSignalPostResult = IM4Data.RemoteRTCSignalPostResult

typealias RemoteRTCSessionDescriptionSignalData = IM4Data.RemoteRTCSessionDescriptionSignalData

extension RemoteRTCSessionDescriptionSignalData {
    var isOfferOrAnswer: Bool {
        ["offer", "answer"].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

typealias RemoteRTCIceCandidateSignalData = IM4Data.RemoteRTCIceCandidateSignalData

typealias RemoteRTCIceCandidatesSignalData = IM4Data.RemoteRTCIceCandidatesSignalData

typealias RemoteRTCByeSignalData = IM4Data.RemoteRTCByeSignalData
// WDT_IOS1_DATA_RTC_WIRE_FAMILY_20261110_END

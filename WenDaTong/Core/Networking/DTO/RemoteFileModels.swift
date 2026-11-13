import Foundation
import IM4Data

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteGroupFile = IM4Data.RemoteGroupFile

extension RemoteGroupFile {
    var channelScopeText: String {
        switch channelType {
        case "group":
            return "群文件"
        case "direct":
            return "私聊文件"
        default:
            return channelID.isEmpty ? "文件模块" : channelID
        }
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteFavoriteAssetsResponse = IM4Data.RemoteFavoriteAssetsResponse
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteFavoriteAssetItem = IM4Data.RemoteFavoriteAssetItem

extension RemoteFavoriteAssetItem {
    var resolvedSenderID: String {
        [fromUID, senderUID, senderUserID, fromUserID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteUserFileDetail = IM4Data.RemoteUserFileDetail
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteUserFileObject = IM4Data.RemoteUserFileObject
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

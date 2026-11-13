import Foundation
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteGroupJoinRequest = IM4Data.RemoteGroupJoinRequest
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteCreateGroupJoinRequestResponse = IM4Data.RemoteCreateGroupJoinRequestResponse

extension RemoteCreateGroupJoinRequestResponse {
    var requiresApproval: Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestStatus = request?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["pending", "pending_approval", "waiting_approval", "submitted"].contains(normalizedStatus)
            || ["pending", "pending_approval", "waiting_approval", "submitted"].contains(requestStatus)
            || !joinRequests.isEmpty
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteGroupDNDResult = IM4Data.RemoteGroupDNDResult
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteRawGroup = IM4Data.RemoteRawGroup
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteGroupProfileUpdateResponse = IM4Data.RemoteGroupProfileUpdateResponse
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteCreateGroupResponse = IM4Data.RemoteCreateGroupResponse
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteInviteGroupMembersResponse = IM4Data.RemoteInviteGroupMembersResponse

extension RemoteInviteGroupMembersResponse {
    var requiresApproval: Bool {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pendingApproval
            || !joinRequests.isEmpty
            || ["pending", "pending_approval", "waiting_approval", "submitted"].contains(normalizedStatus)
    }

    var invitationResultMessage: String {
        var parts: [String] = []
        if !items.isEmpty { parts.append("已邀请 \(items.count) 人入群") }
        if requiresApproval {
            parts.append(joinRequests.isEmpty ? "已提交入群邀请，等待审核" : "\(joinRequests.count) 人等待审核")
        }
        if alreadyMemberCount > 0 { parts.append("\(alreadyMemberCount) 人已在群中") }
        if parts.isEmpty && status == "already_member" { return "所选成员已在群中" }
        return parts.isEmpty ? "邀请结果已同步" : parts.joined(separator: "，")
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteGroup = IM4Data.RemoteGroup
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
typealias RemoteGroupMember = IM4Data.RemoteGroupMember
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteCreateGroupJoinRequestResponse: Decodable, Sendable {
    public let status: String
    public let request: RemoteGroupJoinRequest?
    public let joinRequests: [RemoteGroupJoinRequest]
    public let notifications: [RemoteInboxEntry]
    public let systemMessages: [RemoteMessage]
    public let items: [RemoteGroupMember]

    enum CodingKeys: String, CodingKey {
        case status
        case request
        case joinRequests = "join_requests"
        case requests
        case notifications
        case systemMessages = "system_messages"
        case items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        request = try c.decodeIfPresent(RemoteGroupJoinRequest.self, forKey: .request)
        joinRequests = try c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .joinRequests)
            ?? c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .requests)
            ?? []
        notifications = (try? c.decodeIfPresent([RemoteInboxEntry].self, forKey: .notifications)) ?? []
        systemMessages = try c.decodeIfPresent([RemoteMessage].self, forKey: .systemMessages) ?? []
        items = try c.decodeIfPresent([RemoteGroupMember].self, forKey: .items) ?? []
    }

    public init(
        status: String,
        request: RemoteGroupJoinRequest?,
        joinRequests: [RemoteGroupJoinRequest],
        notifications: [RemoteInboxEntry],
        systemMessages: [RemoteMessage],
        items: [RemoteGroupMember]
    ) {
        self.status = status
        self.request = request
        self.joinRequests = joinRequests
        self.notifications = notifications
        self.systemMessages = systemMessages
        self.items = items
    }
}

public struct RemoteCreateGroupResponse: Decodable, Sendable {
    public let group: RemoteRawGroup
    public let members: [RemoteGroupMember]
    public let systemMessages: [RemoteMessage]

    enum CodingKeys: String, CodingKey {
        case group
        case members
        case systemMessages = "system_messages"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(RemoteRawGroup.self, forKey: .group) ?? RemoteRawGroup(groupID: "")
        members = try c.decodeIfPresent([RemoteGroupMember].self, forKey: .members) ?? []
        systemMessages = try c.decodeIfPresent([RemoteMessage].self, forKey: .systemMessages) ?? []
    }

    public init(
        group: RemoteRawGroup,
        members: [RemoteGroupMember],
        systemMessages: [RemoteMessage]
    ) {
        self.group = group
        self.members = members
        self.systemMessages = systemMessages
    }
}

public struct RemoteInviteGroupMembersResponse: Decodable, Sendable {
    public let alreadyMemberCount: Int
    public let items: [RemoteGroupMember]
    public let systemMessages: [RemoteMessage]
    public let status: String
    public let joinRequests: [RemoteGroupJoinRequest]
    public let notifications: [RemoteInboxEntry]
    public let pendingApproval: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case alreadyMembers = "already_members"
        case systemMessages = "system_messages"
        case status
        case joinRequests = "join_requests"
        case requests
        case notifications
        case pendingApproval = "pending_approval"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alreadyMemberCount = (try? c.decode([JSONValue].self, forKey: .alreadyMembers))?.count ?? 0
        items = try c.decodeIfPresent([RemoteGroupMember].self, forKey: .items) ?? []
        systemMessages = try c.decodeIfPresent([RemoteMessage].self, forKey: .systemMessages) ?? []
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        joinRequests = try c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .joinRequests)
            ?? c.decodeIfPresent([RemoteGroupJoinRequest].self, forKey: .requests)
            ?? []
        notifications = (try? c.decodeIfPresent([RemoteInboxEntry].self, forKey: .notifications)) ?? []
        pendingApproval = try c.decodeIfPresent(Bool.self, forKey: .pendingApproval) ?? false
    }



    // WDT_APP_CONTRACT_20261021_12: report server results, never count requested IDs as joined.

    public init(
        alreadyMemberCount: Int,
        items: [RemoteGroupMember],
        systemMessages: [RemoteMessage],
        status: String,
        joinRequests: [RemoteGroupJoinRequest],
        notifications: [RemoteInboxEntry],
        pendingApproval: Bool
    ) {
        self.alreadyMemberCount = alreadyMemberCount
        self.items = items
        self.systemMessages = systemMessages
        self.status = status
        self.joinRequests = joinRequests
        self.notifications = notifications
        self.pendingApproval = pendingApproval
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteTenantDirectoryResult: Sendable {
    public let appID: String

    public let appScoped: Bool

    public let workspaceCount: Int

    public let enterableWorkspaceCount: Int

    public let selectionMode: String

    public let emptyReason: String

    public let entryStatus: String

    public let pendingEntryTenantID: String

    public let pendingApprovalCount: Int

    public let requiresWorkspaceSelection: Bool?

    public let items: [RemoteTenantMembership]

    public let workspaces: [RemoteTenantMembership]

    public init(
        wireAppID appID: String,
        appScoped: Bool,
        workspaceCount: Int,
        enterableWorkspaceCount: Int,
        selectionMode: String,
        emptyReason: String,
        entryStatus: String,
        pendingEntryTenantID: String,
        pendingApprovalCount: Int,
        requiresWorkspaceSelection: Bool?,
        items: [RemoteTenantMembership],
        workspaces: [RemoteTenantMembership]
    ) {
        self.appID = appID
        self.appScoped = appScoped
        self.workspaceCount = workspaceCount
        self.enterableWorkspaceCount = enterableWorkspaceCount
        self.selectionMode = selectionMode
        self.emptyReason = emptyReason
        self.entryStatus = entryStatus
        self.pendingEntryTenantID = pendingEntryTenantID
        self.pendingApprovalCount = pendingApprovalCount
        self.requiresWorkspaceSelection = requiresWorkspaceSelection
        self.items = items
        self.workspaces = workspaces
    }
}

public struct RemoteGroupMembersResult: Sendable {
    public let items: [RemoteUserGroupMember]
    public let selfMember: RemoteUserGroupMember?
    public let total: Int?
    public let limit: Int?
    public let offset: Int?
    public let hasMore: Bool?
    public let nextOffset: Int?
    public let nextCursor: String?

    public init(
        items: [RemoteUserGroupMember],
        selfMember: RemoteUserGroupMember? = nil,
        total: Int?,
        limit: Int? = nil,
        offset: Int? = nil,
        hasMore: Bool? = nil,
        nextOffset: Int? = nil,
        nextCursor: String? = nil
    ) {
        self.items = items
        self.selfMember = selfMember
        self.total = total
        self.limit = limit
        self.offset = offset
        self.hasMore = hasMore
        self.nextOffset = nextOffset
        self.nextCursor = nextCursor
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

import Foundation
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
import IM4Data
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteTenantDirectoryResult = IM4Data.RemoteTenantDirectoryResult

extension RemoteTenantDirectoryResult: @retroactive Decodable {
    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case appScoped = "app_scoped"
        case appScopedCamel = "appScoped"
        case workspaceCount = "workspace_count"
        case workspaceCountCamel = "workspaceCount"
        case enterableWorkspaceCount = "enterable_workspace_count"
        case enterableWorkspaceCountCamel = "enterableWorkspaceCount"
        case selectionMode = "selection_mode"
        case selectionModeCamel = "selectionMode"
        case emptyReason = "empty_reason"
        case emptyReasonCamel = "emptyReason"
        case entryStatus = "entry_status"
        case entryStatusCamel = "entryStatus"
        case pendingEntryTenantID = "pending_entry_tenant_id"
        case pendingEntryTenantIDCamel = "pendingEntryTenantId"
        case pendingApprovalCount = "pending_approval_count"
        case pendingApprovalCountCamel = "pendingApprovalCount"
        case requiresWorkspaceSelection = "requires_workspace_selection"
        case requiresWorkspaceSelectionCamel = "requiresWorkspaceSelection"
        case items
        case memberships
        case workspaces
        case tenants
    }

    var preferredMemberships: [RemoteTenantMembership] {
        workspaces.isEmpty ? items : workspaces
    }

    public init(from decoder: Decoder) throws {
        let appID: String
        let appScoped: Bool
        let workspaceCount: Int
        let enterableWorkspaceCount: Int
        let selectionMode: String
        let emptyReason: String
        let entryStatus: String
        let pendingEntryTenantID: String
        let pendingApprovalCount: Int
        let requiresWorkspaceSelection: Bool?
        let items: [RemoteTenantMembership]
        let workspaces: [RemoteTenantMembership]
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        appScoped = c.decodeLossyBoolIfPresent(forKey: .appScoped)
            ?? c.decodeLossyBoolIfPresent(forKey: .appScopedCamel)
            ?? false
        workspaceCount = c.decodeLossyIntIfPresent(forKey: .workspaceCount)
            ?? c.decodeLossyIntIfPresent(forKey: .workspaceCountCamel)
            ?? 0
        enterableWorkspaceCount = c.decodeLossyIntIfPresent(forKey: .enterableWorkspaceCount)
            ?? c.decodeLossyIntIfPresent(forKey: .enterableWorkspaceCountCamel)
            ?? 0
        selectionMode = try c.decodeIfPresent(String.self, forKey: .selectionMode)
            ?? c.decodeIfPresent(String.self, forKey: .selectionModeCamel)
            ?? ""
        emptyReason = try c.decodeIfPresent(String.self, forKey: .emptyReason)
            ?? c.decodeIfPresent(String.self, forKey: .emptyReasonCamel)
            ?? ""
        entryStatus = try c.decodeIfPresent(String.self, forKey: .entryStatus)
            ?? c.decodeIfPresent(String.self, forKey: .entryStatusCamel)
            ?? ""
        pendingEntryTenantID = try c.decodeIfPresent(String.self, forKey: .pendingEntryTenantID)
            ?? c.decodeIfPresent(String.self, forKey: .pendingEntryTenantIDCamel)
            ?? ""
        pendingApprovalCount = c.decodeLossyIntIfPresent(forKey: .pendingApprovalCount)
            ?? c.decodeLossyIntIfPresent(forKey: .pendingApprovalCountCamel)
            ?? 0
        requiresWorkspaceSelection = c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelection)
            ?? c.decodeLossyBoolIfPresent(forKey: .requiresWorkspaceSelectionCamel)
        let decodedItems = try c.decodeIfPresent([RemoteTenantMembership].self, forKey: .items)
            ?? c.decodeIfPresent([RemoteTenantMembership].self, forKey: .memberships)
            ?? []
        items = decodedItems
        workspaces = try c.decodeIfPresent([RemoteTenantMembership].self, forKey: .workspaces)
            ?? c.decodeIfPresent([RemoteTenantMembership].self, forKey: .tenants)
            ?? []
        self.init(
            wireAppID: appID,
            appScoped: appScoped,
            workspaceCount: workspaceCount,
            enterableWorkspaceCount: enterableWorkspaceCount,
            selectionMode: selectionMode,
            emptyReason: emptyReason,
            entryStatus: entryStatus,
            pendingEntryTenantID: pendingEntryTenantID,
            pendingApprovalCount: pendingApprovalCount,
            requiresWorkspaceSelection: requiresWorkspaceSelection,
            items: items,
            workspaces: workspaces
        )
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteGroupMembersResult = IM4Data.RemoteGroupMembersResult
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

enum GroupNicknameInputError: Error, Equatable {
    case tooLong
    case containsControlCharacter

    var userMessage: String {
        switch self {
        case .tooLong:
            return "群昵称最多 64 个字符"
        case .containsControlCharacter:
            return "群昵称不能包含控制字符或换行"
        }
    }
}

enum GroupNicknameInputPolicy {
    static let maximumUnicodeScalarCount = 64
    private static let bidiControlScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    static func normalize(_ rawValue: String) throws -> String {
        let normalized = rawValue
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.unicodeScalars.count > maximumUnicodeScalarCount {
            throw GroupNicknameInputError.tooLong
        }
        if normalized.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || bidiControlScalars.contains(scalar.value)
        }) {
            throw GroupNicknameInputError.containsControlCharacter
        }
        return normalized
    }
}

enum GroupMemberDisplayNameResolver {
    static func resolve(
        authoritativeDisplayName: String,
        viewerRemarks: [String?],
        groupNickname: String,
        globalNickname: String,
        stableIdentifier: String,
        isCurrentUser: Bool
    ) -> String {
        let nickname = groupNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty { return nickname }
        if !isCurrentUser {
            for candidate in viewerRemarks {
                if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        // Explicit fields define the current contract. Older servers may still
        // project a contact remark into display_name, ahead of group_nickname.
        return [globalNickname, authoritativeDisplayName, stableIdentifier]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名成员"
    }

    static func projectedName(for user: IMUser) -> String {
        [user.name, user.username, user.userID, user.id]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名成员"
    }
}

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteDepartmentNode = IM4Data.RemoteDepartmentNode
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteOrganizationTree = IM4Data.RemoteOrganizationTree
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteOrganizationMemberView = IM4Data.RemoteOrganizationMemberView
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_BEGIN
typealias RemoteOrganizationMemberList = IM4Data.RemoteOrganizationMemberList
// WDT_IOS1_DATA_DIRECTORY_CONTACT_DTO_20261110_END

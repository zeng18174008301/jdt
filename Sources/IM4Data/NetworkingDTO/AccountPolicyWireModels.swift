import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteTenantContext: Sendable {
    public let tenantID: String

    public let imUID: String

    public let appID: String

    public let deviceID: String

    public let tenant: RemoteTenantProfile

    public let user: RemoteIMUser?

    public let departmentEnabled: Bool?

    public let clientPolicy: RemoteTenantClientPolicy?

    public init(
        wireTenantID tenantID: String,
        imUID: String,
        appID: String,
        deviceID: String,
        tenant: RemoteTenantProfile,
        user: RemoteIMUser?,
        departmentEnabled: Bool?,
        clientPolicy: RemoteTenantClientPolicy?
    ) {
        self.tenantID = tenantID
        self.imUID = imUID
        self.appID = appID
        self.deviceID = deviceID
        self.tenant = tenant
        self.user = user
        self.departmentEnabled = departmentEnabled
        self.clientPolicy = clientPolicy
    }
}

public struct RemoteTenantClientPolicy: Decodable, Equatable, Sendable {
    public let allowMemberGroupCreation: Bool
    public let hideMembershipSystemMessages: Bool
    public let clientFriendRequests: Bool
    public let showGroupMemberCount: Bool
    public let groupMemberCountPolicyGeneration: Int64
    public let groupMemberCountContractVersion: Int
    public let groupMemberCountPolicyAuthoritative: Bool
    public let groupMemberCountPolicyPresent: Bool
    public let showOnlineStatus: Bool
    public let showLastLoginTime: Bool
    public let loginRequireBoundDevice: Bool
    public let multiDeviceEnabled: Bool
    public let multiDeviceContractVersion: Int
    public let multiDevicePolicyAuthoritative: Bool
    public let multiDevicePolicyPresent: Bool
    public let messageExportEnabled: Bool
    public let mediaOfflinePolicy: String
    public let mediaOfflinePolicyPresent: Bool

    enum CodingKeys: String, CodingKey {
        case group
        case relationship
        case visibility
        case device
        case export
        case mediaCache = "media_cache"
        case mediaCacheCamel = "mediaCache"
        case mediaOfflinePolicy = "media_offline_policy"
        case mediaOfflinePolicyCamel = "mediaOfflinePolicy"
        case allowMemberGroupCreation = "allow_member_group_creation"
        case allowMemberGroupCreationCamel = "allowMemberGroupCreation"
        case onlyInternalCanCreateGroup = "only_internal_can_create_group"
        case onlyInternalCanCreateGroupCamel = "onlyInternalCanCreateGroup"
        case hideMembershipSystemMessages = "hide_membership_system_messages"
        case hideMembershipSystemMessagesCamel = "hideMembershipSystemMessages"
        case clientFriendRequests = "client_friend_requests"
        case clientFriendRequestsCamel = "clientFriendRequests"
        case showGroupMemberCount = "show_group_member_count"
        case showGroupMemberCountCamel = "showGroupMemberCount"
        case tenantPolicyGeneration = "tenant_policy_generation"
        case tenantPolicyGenerationCamel = "tenantPolicyGeneration"
        case contractVersion = "contract_version"
        case contractVersionCamel = "contractVersion"
        case authoritative
        case showOnlineStatus = "show_online_status"
        case showOnlineStatusCamel = "showOnlineStatus"
        case showLastLoginTime = "show_last_login_time"
        case showLastLoginTimeCamel = "showLastLoginTime"
        case loginRequireBoundDevice = "login_require_bound_device"
        case loginRequireBoundDeviceCamel = "loginRequireBoundDevice"
        case messageExportEnabled = "message_export_enabled"
        case messageExportEnabledCamel = "messageExportEnabled"
    }

    enum GroupCodingKeys: String, CodingKey {
        case allowMemberGroupCreation = "allow_member_group_creation"
        case allowMemberGroupCreationCamel = "allowMemberGroupCreation"
        case onlyInternalCanCreateGroup = "only_internal_can_create_group"
        case onlyInternalCanCreateGroupCamel = "onlyInternalCanCreateGroup"
        case hideMembershipSystemMessages = "hide_membership_system_messages"
        case hideMembershipSystemMessagesCamel = "hideMembershipSystemMessages"
    }

    enum RelationshipCodingKeys: String, CodingKey {
        case clientFriendRequests = "client_friend_requests"
        case clientFriendRequestsCamel = "clientFriendRequests"
    }

    enum VisibilityCodingKeys: String, CodingKey {
        case showGroupMemberCount = "show_group_member_count"
        case showGroupMemberCountCamel = "showGroupMemberCount"
        case tenantPolicyGeneration = "tenant_policy_generation"
        case tenantPolicyGenerationCamel = "tenantPolicyGeneration"
        case contractVersion = "contract_version"
        case contractVersionCamel = "contractVersion"
        case authoritative
        case showOnlineStatus = "show_online_status"
        case showOnlineStatusCamel = "showOnlineStatus"
        case showLastLoginTime = "show_last_login_time"
        case showLastLoginTimeCamel = "showLastLoginTime"
    }

    enum DeviceCodingKeys: String, CodingKey {
        case loginRequireBoundDevice = "login_require_bound_device"
        case loginRequireBoundDeviceCamel = "loginRequireBoundDevice"
        case multiDeviceEnabled = "multi_device_enabled"
        case authoritative
        case contractVersion = "contract_version"
    }

    enum ExportCodingKeys: String, CodingKey {
        case messageExportEnabled = "message_export_enabled"
        case messageExportEnabledCamel = "messageExportEnabled"
    }

    enum MediaCacheCodingKeys: String, CodingKey {
        case offlinePolicy = "offline_policy"
        case offlinePolicyCamel = "offlinePolicy"
    }

    public init(
        allowMemberGroupCreation: Bool = false,
        hideMembershipSystemMessages: Bool = false,
        clientFriendRequests: Bool = false,
        showGroupMemberCount: Bool = false,
        groupMemberCountPolicyGeneration: Int64 = 0,
        groupMemberCountContractVersion: Int = 0,
        groupMemberCountPolicyAuthoritative: Bool = false,
        groupMemberCountPolicyPresent: Bool = false,
        showOnlineStatus: Bool = true,
        showLastLoginTime: Bool = false,
        loginRequireBoundDevice: Bool = false,
        multiDeviceEnabled: Bool = false,
        multiDeviceContractVersion: Int = 0,
        multiDevicePolicyAuthoritative: Bool = false,
        multiDevicePolicyPresent: Bool = false,
        messageExportEnabled: Bool = false,
        mediaOfflinePolicy: String = "standard",
        mediaOfflinePolicyPresent: Bool = false
    ) {
        self.allowMemberGroupCreation = allowMemberGroupCreation
        self.hideMembershipSystemMessages = hideMembershipSystemMessages
        self.clientFriendRequests = clientFriendRequests
        self.showGroupMemberCount = showGroupMemberCount
        self.groupMemberCountPolicyGeneration = max(0, groupMemberCountPolicyGeneration)
        self.groupMemberCountContractVersion = max(0, groupMemberCountContractVersion)
        self.groupMemberCountPolicyAuthoritative = groupMemberCountPolicyAuthoritative
        self.groupMemberCountPolicyPresent = groupMemberCountPolicyPresent
        self.showOnlineStatus = showOnlineStatus
        self.showLastLoginTime = showLastLoginTime
        self.loginRequireBoundDevice = loginRequireBoundDevice
        self.multiDeviceEnabled = multiDeviceEnabled
        self.multiDeviceContractVersion = max(0, multiDeviceContractVersion)
        self.multiDevicePolicyAuthoritative = multiDevicePolicyAuthoritative
        self.multiDevicePolicyPresent = multiDevicePolicyPresent
        self.messageExportEnabled = messageExportEnabled
        self.mediaOfflinePolicy = mediaOfflinePolicy
        self.mediaOfflinePolicyPresent = mediaOfflinePolicyPresent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let group = try? c.nestedContainer(keyedBy: GroupCodingKeys.self, forKey: .group)
        let relationship = try? c.nestedContainer(keyedBy: RelationshipCodingKeys.self, forKey: .relationship)
        let visibility = try? c.nestedContainer(keyedBy: VisibilityCodingKeys.self, forKey: .visibility)
        let device = try? c.nestedContainer(keyedBy: DeviceCodingKeys.self, forKey: .device)
        let export = try? c.nestedContainer(keyedBy: ExportCodingKeys.self, forKey: .export)
        let mediaCache = (try? c.nestedContainer(keyedBy: MediaCacheCodingKeys.self, forKey: .mediaCache))
            ?? (try? c.nestedContainer(keyedBy: MediaCacheCodingKeys.self, forKey: .mediaCacheCamel))

        let explicitMemberCreate = group?.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreation)
            ?? group?.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreationCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreation)
            ?? c.decodeLossyBoolIfPresent(forKey: .allowMemberGroupCreationCamel)
        let compatOnlyInternal = group?.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroup)
            ?? group?.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroupCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroup)
            ?? c.decodeLossyBoolIfPresent(forKey: .onlyInternalCanCreateGroupCamel)
        allowMemberGroupCreation = explicitMemberCreate ?? compatOnlyInternal.map { !$0 } ?? false
        hideMembershipSystemMessages = group?.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessages)
            ?? group?.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessagesCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessages)
            ?? c.decodeLossyBoolIfPresent(forKey: .hideMembershipSystemMessagesCamel)
            ?? false
        clientFriendRequests = relationship?.decodeLossyBoolIfPresent(forKey: .clientFriendRequests)
            ?? relationship?.decodeLossyBoolIfPresent(forKey: .clientFriendRequestsCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .clientFriendRequests)
            ?? c.decodeLossyBoolIfPresent(forKey: .clientFriendRequestsCamel)
            ?? false
        let strictShowGroupMemberCount =
            visibility?.decodeStrictBoolIfPresent(forKey: .showGroupMemberCount)
                ?? visibility?.decodeStrictBoolIfPresent(forKey: .showGroupMemberCountCamel)
                ?? c.decodeStrictBoolIfPresent(forKey: .showGroupMemberCount)
                ?? c.decodeStrictBoolIfPresent(forKey: .showGroupMemberCountCamel)
        let strictGroupMemberCountGeneration =
            visibility?.decodeStrictInt64IfPresent(forKey: .tenantPolicyGeneration)
                ?? visibility?.decodeStrictInt64IfPresent(forKey: .tenantPolicyGenerationCamel)
                ?? c.decodeStrictInt64IfPresent(forKey: .tenantPolicyGeneration)
                ?? c.decodeStrictInt64IfPresent(forKey: .tenantPolicyGenerationCamel)
        let strictGroupMemberCountContractVersion =
            visibility?.decodeStrictIntIfPresent(forKey: .contractVersion)
                ?? visibility?.decodeStrictIntIfPresent(forKey: .contractVersionCamel)
                ?? c.decodeStrictIntIfPresent(forKey: .contractVersion)
                ?? c.decodeStrictIntIfPresent(forKey: .contractVersionCamel)
        let strictGroupMemberCountAuthoritative =
            visibility?.decodeStrictBoolIfPresent(forKey: .authoritative)
                ?? c.decodeStrictBoolIfPresent(forKey: .authoritative)
        showGroupMemberCount = strictShowGroupMemberCount ?? false
        groupMemberCountPolicyGeneration = max(0, strictGroupMemberCountGeneration ?? 0)
        groupMemberCountContractVersion = max(0, strictGroupMemberCountContractVersion ?? 0)
        groupMemberCountPolicyAuthoritative = strictGroupMemberCountAuthoritative ?? false
        let hasShowGroupMemberCount =
            visibility?.contains(.showGroupMemberCount) == true ||
            visibility?.contains(.showGroupMemberCountCamel) == true ||
            c.contains(.showGroupMemberCount) ||
            c.contains(.showGroupMemberCountCamel)
        let hasGroupMemberCountGeneration =
            visibility?.contains(.tenantPolicyGeneration) == true ||
            visibility?.contains(.tenantPolicyGenerationCamel) == true ||
            c.contains(.tenantPolicyGeneration) ||
            c.contains(.tenantPolicyGenerationCamel)
        let hasGroupMemberCountContractVersion =
            visibility?.contains(.contractVersion) == true ||
            visibility?.contains(.contractVersionCamel) == true ||
            c.contains(.contractVersion) ||
            c.contains(.contractVersionCamel)
        let hasGroupMemberCountAuthoritative =
            visibility?.contains(.authoritative) == true ||
            c.contains(.authoritative)
        let hasInvalidShowGroupMemberCount =
            visibility?.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCount) == true ||
            visibility?.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCountCamel) == true ||
            c.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCount) ||
            c.containsInvalidStrictValue(Bool.self, forKey: .showGroupMemberCountCamel)
        let hasInvalidGroupMemberCountGeneration =
            visibility?.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGeneration) == true ||
            visibility?.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGenerationCamel) == true ||
            c.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGeneration) ||
            c.containsInvalidStrictValue(Int64.self, forKey: .tenantPolicyGenerationCamel)
        let hasInvalidGroupMemberCountContractVersion =
            visibility?.containsInvalidStrictValue(Int.self, forKey: .contractVersion) == true ||
            visibility?.containsInvalidStrictValue(Int.self, forKey: .contractVersionCamel) == true ||
            c.containsInvalidStrictValue(Int.self, forKey: .contractVersion) ||
            c.containsInvalidStrictValue(Int.self, forKey: .contractVersionCamel)
        let hasInvalidGroupMemberCountAuthoritative =
            visibility?.containsInvalidStrictValue(Bool.self, forKey: .authoritative) == true ||
            c.containsInvalidStrictValue(Bool.self, forKey: .authoritative)
        groupMemberCountPolicyPresent =
            hasShowGroupMemberCount &&
            hasGroupMemberCountGeneration &&
            hasGroupMemberCountContractVersion &&
            hasGroupMemberCountAuthoritative &&
            !hasInvalidShowGroupMemberCount &&
            !hasInvalidGroupMemberCountGeneration &&
            !hasInvalidGroupMemberCountContractVersion &&
            !hasInvalidGroupMemberCountAuthoritative &&
            strictShowGroupMemberCount != nil &&
            strictGroupMemberCountGeneration.map { $0 >= 0 } == true &&
            strictGroupMemberCountContractVersion.map { $0 >= 1 } == true &&
            strictGroupMemberCountAuthoritative != nil
        showOnlineStatus = visibility?.decodeLossyBoolIfPresent(forKey: .showOnlineStatus)
            ?? visibility?.decodeLossyBoolIfPresent(forKey: .showOnlineStatusCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .showOnlineStatus)
            ?? c.decodeLossyBoolIfPresent(forKey: .showOnlineStatusCamel)
            ?? true
        showLastLoginTime = visibility?.decodeLossyBoolIfPresent(forKey: .showLastLoginTime)
            ?? visibility?.decodeLossyBoolIfPresent(forKey: .showLastLoginTimeCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .showLastLoginTime)
            ?? c.decodeLossyBoolIfPresent(forKey: .showLastLoginTimeCamel)
            ?? false
        loginRequireBoundDevice = device?.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDevice)
            ?? device?.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDeviceCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDevice)
            ?? c.decodeLossyBoolIfPresent(forKey: .loginRequireBoundDeviceCamel)
            ?? false
        let strictMultiDeviceEnabled = device?.decodeStrictBoolIfPresent(forKey: .multiDeviceEnabled)
        let strictMultiDeviceAuthoritative = device?.decodeStrictBoolIfPresent(forKey: .authoritative)
        let strictMultiDeviceContractVersion = device?.decodeStrictIntIfPresent(forKey: .contractVersion)
        let hasMultiDeviceEnabled = device?.contains(.multiDeviceEnabled) == true
        let hasMultiDeviceAuthoritative = device?.contains(.authoritative) == true
        let hasMultiDeviceContractVersion = device?.contains(.contractVersion) == true
        let hasInvalidMultiDeviceEnabled =
            device?.containsInvalidStrictValue(Bool.self, forKey: .multiDeviceEnabled) == true
        let hasInvalidMultiDeviceAuthoritative =
            device?.containsInvalidStrictValue(Bool.self, forKey: .authoritative) == true
        let hasInvalidMultiDeviceContractVersion =
            device?.containsInvalidStrictValue(Int.self, forKey: .contractVersion) == true
        multiDeviceEnabled = strictMultiDeviceEnabled ?? false
        multiDeviceContractVersion = max(0, strictMultiDeviceContractVersion ?? 0)
        multiDevicePolicyAuthoritative = strictMultiDeviceAuthoritative ?? false
        multiDevicePolicyPresent =
            hasMultiDeviceEnabled &&
            hasMultiDeviceAuthoritative &&
            hasMultiDeviceContractVersion &&
            !hasInvalidMultiDeviceEnabled &&
            !hasInvalidMultiDeviceAuthoritative &&
            !hasInvalidMultiDeviceContractVersion &&
            strictMultiDeviceEnabled != nil &&
            strictMultiDeviceAuthoritative == true &&
            strictMultiDeviceContractVersion == 1
        messageExportEnabled = export?.decodeLossyBoolIfPresent(forKey: .messageExportEnabled)
            ?? export?.decodeLossyBoolIfPresent(forKey: .messageExportEnabledCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .messageExportEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .messageExportEnabledCamel)
            ?? false
        let decodedMediaOfflinePolicy = (try? mediaCache?.decodeIfPresent(String.self, forKey: .offlinePolicy))
            ?? (try? mediaCache?.decodeIfPresent(String.self, forKey: .offlinePolicyCamel))
            ?? (try? c.decodeIfPresent(String.self, forKey: .mediaOfflinePolicy))
            ?? (try? c.decodeIfPresent(String.self, forKey: .mediaOfflinePolicyCamel))
        mediaOfflinePolicy = decodedMediaOfflinePolicy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "standard"
        mediaOfflinePolicyPresent = decodedMediaOfflinePolicy != nil
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

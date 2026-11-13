// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_BEGIN
import Foundation

public struct SearchInvalidationEvent: Decodable, Sendable, Equatable {
    public let tenantID: String
    public let invalidationKey: String
    public let eventType: String
    public let reason: String
    public let channelID: String?
    public let channelType: String?
    public let channelSeq: Int64?
    public let messageID: String?
    public let fileID: String?
    public let version: Int64
    public let updatedAt: String?
    public let clientAction: String?
    public let isTenantScopeReset: Bool

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case tenantIDCamel = "tenantId"
        case invalidationKey = "invalidation_key"
        case invalidationKeyCamel = "invalidationKey"
        case eventType = "event_type"
        case eventTypeCamel = "eventType"
        case searchInvalidationType = "search_invalidation_type"
        case searchInvalidationAction = "search_invalidation_action"
        case reason
        case channelID = "channel_id"
        case channelIDCamel = "channelId"
        case channelType = "channel_type"
        case channelTypeCamel = "channelType"
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case fileID = "file_id"
        case fileIDCamel = "fileId"
        case version
        case updatedAt = "updated_at"
        case updatedAtCamel = "updatedAt"
        case clientAction = "client_action"
        case clientActionCamel = "clientAction"
        case searchInvalidationActionCamel = "searchInvalidationAction"
        case reset
        case clear
    }

    public init(
        tenantID: String = "",
        invalidationKey: String = "",
        eventType: String = "",
        reason: String = "",
        channelID: String? = nil,
        channelType: String? = nil,
        channelSeq: Int64? = nil,
        messageID: String? = nil,
        fileID: String? = nil,
        version: Int64 = 0,
        updatedAt: String? = nil,
        clientAction: String? = nil,
        isTenantScopeReset: Bool = false
    ) {
        self.tenantID = tenantID
        self.invalidationKey = invalidationKey
        self.eventType = eventType
        self.reason = reason
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.messageID = messageID
        self.fileID = fileID
        self.version = version
        self.updatedAt = updatedAt
        self.clientAction = clientAction
        self.isTenantScopeReset = isTenantScopeReset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tenantID = try c.decodeIfPresent(String.self, forKey: .tenantID)
            ?? c.decodeIfPresent(String.self, forKey: .tenantIDCamel)
            ?? ""
        let eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
            ?? c.decodeIfPresent(String.self, forKey: .eventTypeCamel)
            ?? c.decodeIfPresent(String.self, forKey: .searchInvalidationType)
            ?? ""
        let clientAction = try c.decodeIfPresent(String.self, forKey: .clientAction)
            ?? c.decodeIfPresent(String.self, forKey: .clientActionCamel)
            ?? c.decodeIfPresent(String.self, forKey: .searchInvalidationAction)
            ?? c.decodeIfPresent(String.self, forKey: .searchInvalidationActionCamel)
        self.init(
            tenantID: tenantID,
            invalidationKey: try c.decodeIfPresent(String.self, forKey: .invalidationKey)
                ?? c.decodeIfPresent(String.self, forKey: .invalidationKeyCamel)
                ?? "",
            eventType: eventType,
            reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
            channelID: try c.decodeIfPresent(String.self, forKey: .channelID)
                ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel),
            channelType: try c.decodeIfPresent(String.self, forKey: .channelType)
                ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel),
            channelSeq: c.decodeLossyInt64IfPresent(forKey: .channelSeq)
                ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel),
            messageID: try c.decodeIfPresent(String.self, forKey: .messageID)
                ?? c.decodeIfPresent(String.self, forKey: .messageIDCamel),
            fileID: try c.decodeIfPresent(String.self, forKey: .fileID)
                ?? c.decodeIfPresent(String.self, forKey: .fileIDCamel),
            version: c.decodeLossyInt64IfPresent(forKey: .version) ?? 0,
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt)
                ?? c.decodeIfPresent(String.self, forKey: .updatedAtCamel),
            clientAction: clientAction,
            isTenantScopeReset: c.decodeLossyBoolIfPresent(forKey: .reset) == true
                || c.decodeLossyBoolIfPresent(forKey: .clear) == true
        )
    }
}

public struct RemoteSearchInvalidationResponse: Decodable, Sendable {
    public let searchInvalidations: [SearchInvalidationEvent]

    enum CodingKeys: String, CodingKey {
        case searchInvalidations = "search_invalidations"
        case searchInvalidationsCamel = "searchInvalidations"
    }

    public init(searchInvalidations: [SearchInvalidationEvent] = []) {
        self.searchInvalidations = searchInvalidations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchInvalidations = try c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidations)
            ?? c.decodeIfPresent([SearchInvalidationEvent].self, forKey: .searchInvalidationsCamel)
            ?? []
    }
}
// WDT_IOS1_DATA_GROUP_LIFECYCLE_MUTATION_DTO_20261110_END

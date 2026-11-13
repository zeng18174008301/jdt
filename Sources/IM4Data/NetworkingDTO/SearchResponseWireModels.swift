// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_BEGIN
import Foundation

public struct RemoteMessageSearchResponse: Decodable, Sendable {
    public let items: [RemoteMessageSearchResult]
    public let hasMore: Bool
    public let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}

public struct RemoteMessageSearchResult: Decodable, Sendable {
    public let message: RemoteMessage
    public let matchText: String?

    enum CodingKeys: String, CodingKey {
        case message
        case matchText = "match_text"
    }
}

// WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
public struct RemoteTenantSearchBucketError: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
}
// WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

public struct RemoteTenantSearchResponse: Decodable, Sendable {
    public let query: String
    public let scope: String
    public let types: [String]
    public let limit: Int
    public let searchID: String?
    public let requestID: String?
    public let elapsedMS: Int?
    public let resultsByType: [String: RemoteTenantSearchBucket]
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    public let degraded: Bool
    public let errorsByType: [String: RemoteTenantSearchBucketError]
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
    public let items: [RemoteTenantSearchResult]
    public let compatibility: [String: JSONValue]
    public let analytics: [String: JSONValue]
    public let parsedFilters: [RemoteTenantSearchParsedFilter]
    public let conversationSearch: RemoteTenantConversationSearch?
    public let conversationDateAnchor: RemoteTenantConversationDateAnchor?
    // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
    public let supportsMessageLinks: Bool
    public let appliedMessageLinkFilter: Bool
    // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
    // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
    public let supportsAttachmentMessages: Bool
    public let appliedAttachmentMessageFilter: Bool
    // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END

    enum CodingKeys: String, CodingKey {
        case query
        case scope
        case types
        case limit
        case searchID = "search_id"
        case searchIDCamel = "searchId"
        case requestID = "request_id"
        case requestIDCamel = "requestId"
        case elapsedMS = "elapsed_ms"
        case elapsedMSCamel = "elapsedMs"
        case resultsByType = "results_by_type"
        case resultsByTypeCamel = "resultsByType"
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        case degraded
        case errorsByType = "errors_by_type"
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        case items
        case compatibility
        case analytics
        case parsedFilters = "parsed_filters"
        case parsedFiltersCamel = "parsedFilters"
        case conversationSearch = "conversation_search"
        case conversationSearchCamel = "conversationSearch"
        case conversationDateAnchor = "conversation_date_anchor"
        case conversationDateAnchorCamel = "conversationDateAnchor"
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
        case searchCapabilities = "search_capabilities"
        case appliedFilters = "applied_filters"
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
    }

    public init(
        query: String = "",
        scope: String = "",
        types: [String] = [],
        limit: Int = 0,
        searchID: String? = nil,
        requestID: String? = nil,
        elapsedMS: Int? = nil,
        resultsByType: [String: RemoteTenantSearchBucket] = [:],
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        degraded: Bool = false,
        errorsByType: [String: RemoteTenantSearchBucketError] = [:],
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        items: [RemoteTenantSearchResult] = [],
        compatibility: [String: JSONValue] = [:],
        analytics: [String: JSONValue] = [:],
        parsedFilters: [RemoteTenantSearchParsedFilter] = [],
        conversationSearch: RemoteTenantConversationSearch? = nil,
        conversationDateAnchor: RemoteTenantConversationDateAnchor? = nil,
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
        supportsMessageLinks: Bool = false,
        appliedMessageLinkFilter: Bool = false,
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
        // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
        supportsAttachmentMessages: Bool = false,
        appliedAttachmentMessageFilter: Bool = false
        // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END
    ) {
        self.query = query
        self.scope = scope
        self.types = types
        self.limit = limit
        self.searchID = searchID
        self.requestID = requestID
        self.elapsedMS = elapsedMS
        self.resultsByType = resultsByType
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        self.degraded = degraded
        self.errorsByType = errorsByType
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        self.items = items
        self.compatibility = compatibility
        self.analytics = analytics
        self.parsedFilters = parsedFilters
        self.conversationSearch = conversationSearch
        self.conversationDateAnchor = conversationDateAnchor
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
        self.supportsMessageLinks = supportsMessageLinks
        self.appliedMessageLinkFilter = appliedMessageLinkFilter
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
        // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
        self.supportsAttachmentMessages = supportsAttachmentMessages
        self.appliedAttachmentMessageFilter = appliedAttachmentMessageFilter
        // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        limit = c.decodeLossyIntIfPresent(forKey: .limit) ?? 0
        searchID = try c.decodeIfPresent(String.self, forKey: .searchID)
            ?? c.decodeIfPresent(String.self, forKey: .searchIDCamel)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
            ?? c.decodeIfPresent(String.self, forKey: .requestIDCamel)
        elapsedMS = c.decodeLossyIntIfPresent(forKey: .elapsedMS)
            ?? c.decodeLossyIntIfPresent(forKey: .elapsedMSCamel)
        resultsByType = Self.decodeResultsByType(from: decoder)
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        errorsByType = (try? c.decodeIfPresent([String: RemoteTenantSearchBucketError].self, forKey: .errorsByType)) ?? [:]
        degraded = c.decodeLossyBoolIfPresent(forKey: .degraded) ?? !errorsByType.isEmpty
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        items = try c.decodeIfPresent([RemoteTenantSearchResult].self, forKey: .items) ?? []
        compatibility = try c.decodeIfPresent([String: JSONValue].self, forKey: .compatibility) ?? [:]
        analytics = try c.decodeIfPresent([String: JSONValue].self, forKey: .analytics) ?? [:]
        parsedFilters = try c.decodeIfPresent([RemoteTenantSearchParsedFilter].self, forKey: .parsedFilters)
            ?? c.decodeIfPresent([RemoteTenantSearchParsedFilter].self, forKey: .parsedFiltersCamel)
            ?? []
        conversationSearch = try c.decodeIfPresent(RemoteTenantConversationSearch.self, forKey: .conversationSearch)
            ?? c.decodeIfPresent(RemoteTenantConversationSearch.self, forKey: .conversationSearchCamel)
        conversationDateAnchor = try c.decodeIfPresent(RemoteTenantConversationDateAnchor.self, forKey: .conversationDateAnchor)
            ?? c.decodeIfPresent(RemoteTenantConversationDateAnchor.self, forKey: .conversationDateAnchorCamel)
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_BEGIN
        let capabilities = try? c.decodeIfPresent([String: JSONValue].self, forKey: .searchCapabilities)
        let filters = try? c.decodeIfPresent([String: JSONValue].self, forKey: .appliedFilters)
        supportsMessageLinks = capabilities?["message_links"] == .bool(true)
        appliedMessageLinkFilter = filters?["has_link"] == .bool(true)
        // WDT_IOS1_SEARCH_LINK_FILTER_20261113_END
        // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_BEGIN
        supportsAttachmentMessages = capabilities?["attachment_messages"] == .bool(true)
        appliedAttachmentMessageFilter = filters?["message_content"] == .string("attachment")
        // WDT_IOS1_SEARCH_ATTACHMENT_SENDER_20261113_END
    }

    private static func decodeResultsByType(from decoder: Decoder) -> [String: RemoteTenantSearchBucket] {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return [:] }
        if let value = try? c.decode(RemoteTenantSearchResultsByType.self, forKey: .resultsByType) {
            return value.buckets
        }
        if let value = try? c.decode(RemoteTenantSearchResultsByType.self, forKey: .resultsByTypeCamel) {
            return value.buckets
        }
        return [:]
    }
}

public struct RemoteTenantSearchBucket: Decodable, Sendable {
    public let items: [RemoteTenantSearchResult]
    public let count: Int
    public let hasMore: Bool
    public let nextCursor: String?
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    public let nextCursorV2: String?
    public let totalIsExact: Bool?
    public let status: String?
    public let authoritative: Bool?
    public let error: RemoteTenantSearchBucketError?

    public var exactTotal: Int? {
        totalIsExact == true && authoritative != false ? count : nil
    }
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

    enum CodingKeys: String, CodingKey {
        case items
        case count
        case hasMore = "has_more"
        case hasMoreCamel = "hasMore"
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        case nextCursorV2 = "next_cursor_v2"
        case totalIsExact = "total_is_exact"
        case status, authoritative, error
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
    }

    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
    public init(
        items: [RemoteTenantSearchResult], count: Int? = nil, hasMore: Bool = false,
        nextCursor: String? = nil, nextCursorV2: String? = nil, totalIsExact: Bool? = nil,
        status: String? = nil, authoritative: Bool? = nil, error: RemoteTenantSearchBucketError? = nil
    ) {
        self.items = items
        self.count = count ?? items.count
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.nextCursorV2 = nextCursorV2
        self.totalIsExact = count == nil && totalIsExact == true ? nil : totalIsExact
        self.status = status
        self.authoritative = authoritative
        self.error = error
    }
    // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END

    public init(from decoder: Decoder) throws {
        if let legacyItems = try? [RemoteTenantSearchResult](from: decoder) {
            items = legacyItems
            count = legacyItems.count
            hasMore = false
            nextCursor = nil
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
            nextCursorV2 = nil
            totalIsExact = nil
            status = nil
            authoritative = nil
            error = nil
            // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RemoteTenantSearchResult].self, forKey: .items) ?? []
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_BEGIN
        let reportedCount = c.decodeLossyIntIfPresent(forKey: .count)
        count = reportedCount ?? items.count
        let reportedExactness = c.decodeLossyBoolIfPresent(forKey: .totalIsExact)
        totalIsExact = reportedCount == nil && reportedExactness == true ? nil : reportedExactness
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        authoritative = c.decodeLossyBoolIfPresent(forKey: .authoritative)
        error = try? c.decodeIfPresent(RemoteTenantSearchBucketError.self, forKey: .error)
        nextCursorV2 = try? c.decodeIfPresent(String.self, forKey: .nextCursorV2)
        // WDT_IOS1_TENANT_SEARCH_CONTRACT_20261113_END
        hasMore = c.decodeLossyBoolIfPresent(forKey: .hasMore)
            ?? c.decodeLossyBoolIfPresent(forKey: .hasMoreCamel)
            ?? false
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
    }
}

private struct RemoteTenantSearchResultsByType: Decodable {
    let buckets: [String: RemoteTenantSearchBucket]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RemoteTenantSearchDynamicCodingKey.self)
        var decoded: [String: RemoteTenantSearchBucket] = [:]
        for key in c.allKeys {
            if let bucket = try? c.decode(RemoteTenantSearchBucket.self, forKey: key) {
                decoded[key.stringValue] = bucket
            }
        }
        buckets = decoded
    }
}

private struct RemoteTenantSearchDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_END

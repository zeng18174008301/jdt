// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_BEGIN
import Foundation

public struct RemoteTenantConversationSearch: Decodable, Sendable {
    public let hitChannelSeqs: [Int64]
    public let total: Int
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case hitChannelSeqs = "hit_channel_seqs"
        case hitChannelSeqsCamel = "hitChannelSeqs"
        case total
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hitChannelSeqs = try c.decodeIfPresent([Int64].self, forKey: .hitChannelSeqs)
            ?? c.decodeIfPresent([Int64].self, forKey: .hitChannelSeqsCamel)
            ?? []
        total = c.decodeLossyIntIfPresent(forKey: .total) ?? hitChannelSeqs.count
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .nextCursorCamel)
    }
}

public struct RemoteTenantConversationDateAnchor: Decodable, Equatable, Sendable {
    public let date: String?
    public let status: String
    public let channelSeq: Int64?
    public let messageID: String?
    public let nearestChannelSeq: Int64?
    public let nearestMessageID: String?
    public let direction: String?

    enum CodingKeys: String, CodingKey {
        case date
        case status
        case channelSeq = "channel_seq"
        case channelSeqCamel = "channelSeq"
        case messageID = "message_id"
        case messageIDCamel = "messageId"
        case nearestChannelSeq = "nearest_channel_seq"
        case nearestChannelSeqCamel = "nearestChannelSeq"
        case nearestMessageID = "nearest_message_id"
        case nearestMessageIDCamel = "nearestMessageId"
        case direction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
            ?? c.decodeIfPresent(String.self, forKey: .messageIDCamel)
        nearestChannelSeq = c.decodeLossyInt64IfPresent(forKey: .nearestChannelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .nearestChannelSeqCamel)
        nearestMessageID = try c.decodeIfPresent(String.self, forKey: .nearestMessageID)
            ?? c.decodeIfPresent(String.self, forKey: .nearestMessageIDCamel)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
    }


}

public struct TenantSearchAnalyticsEvent: Sendable {
    public let searchID: String?
    public let requestID: String?
    public let eventType: String
    public let scope: String
    public let types: [String]
    public let resultType: String?
    public let resultID: String?
    public let resultRank: Double?
    public let queryLength: Int
    public let elapsedMS: Int?
    public let filters: [String: String]


    public init(searchID: String?, requestID: String?, eventType: String, scope: String, types: [String], resultType: String?, resultID: String?, resultRank: Double?, queryLength: Int, elapsedMS: Int?, filters: [String: String]) {
        self.searchID = searchID
        self.requestID = requestID
        self.eventType = eventType
        self.scope = scope
        self.types = types
        self.resultType = resultType
        self.resultID = resultID
        self.resultRank = resultRank
        self.queryLength = queryLength
        self.elapsedMS = elapsedMS
        self.filters = filters
    }
}
// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_END

// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_BEGIN
import Foundation

public struct RemoteTenantSearchResult: Decodable, Sendable {
    public let resultID: String
    public let type: String
    public let title: String
    public let subtitle: String?
    public let snippet: String?
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
    public let senderName: String?
    public let occurredAt: String?
    // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
    public let highlightRanges: [RemoteTenantSearchHighlightRange]
    public let rank: Double?
    public let sort: [String: JSONValue]
    public let jumpTarget: RemoteTenantSearchJumpTarget?
    public let sourceName: String?
    public let source: [String: JSONValue]



    enum CodingKeys: String, CodingKey {
        case resultID = "result_id"
        case resultIDCamel = "resultId"
        case type
        case title
        case subtitle
        case snippet
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        case senderName = "sender_name"
        case occurredAt = "occurred_at"
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        case highlightRanges = "highlight_ranges"
        case highlightRangesCamel = "highlightRanges"
        case rank
        case sort
        case jumpTarget = "jump_target"
        case jumpTargetCamel = "jumpTarget"
        case source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resultID = try c.decodeIfPresent(String.self, forKey: .resultID)
            ?? c.decodeIfPresent(String.self, forKey: .resultIDCamel)
            ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_BEGIN
        senderName = try? c.decodeIfPresent(String.self, forKey: .senderName)
        occurredAt = try? c.decodeIfPresent(String.self, forKey: .occurredAt)
        // WDT_IOS1_CHAT_SEARCH_PAGE_20261113_END
        highlightRanges = try c.decodeIfPresent([RemoteTenantSearchHighlightRange].self, forKey: .highlightRanges)
            ?? c.decodeIfPresent([RemoteTenantSearchHighlightRange].self, forKey: .highlightRangesCamel)
            ?? []
        rank = c.decodeLossyDoubleIfPresent(forKey: .rank)
        sort = try c.decodeIfPresent([String: JSONValue].self, forKey: .sort) ?? [:]
        jumpTarget = try c.decodeIfPresent(RemoteTenantSearchJumpTarget.self, forKey: .jumpTarget)
            ?? c.decodeIfPresent(RemoteTenantSearchJumpTarget.self, forKey: .jumpTargetCamel)
        let decodedSource = try c.decodeIfPresent(JSONValue.self, forKey: .source)
        switch decodedSource {
        case .object(let object)?:
            source = object
            sourceName = object["name"]?.stringValue
                ?? object["source"]?.stringValue
                ?? object["type"]?.stringValue
        case .string(let name)?:
            sourceName = name
            source = ["name": .string(name)]
        default:
            sourceName = nil
            source = [:]
        }
    }
}

public struct RemoteTenantSearchParsedFilter: Decodable, Equatable, Sendable {
    public let type: String
    public let key: String
    public let operatorName: String?
    public let value: String
    public let label: String?
    public let raw: String?





    enum CodingKeys: String, CodingKey {
        case type
        case kind
        case key
        case field
        case operatorName = "operator"
        case operatorCamel = "operatorName"
        case op
        case value
        case label
        case raw
        case token
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
            ?? c.decodeIfPresent(String.self, forKey: .kind)
            ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key)
            ?? c.decodeIfPresent(String.self, forKey: .field)
            ?? type
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
            ?? c.decodeIfPresent(String.self, forKey: .operatorCamel)
            ?? c.decodeIfPresent(String.self, forKey: .op)
        let decodedValue = try? c.decodeIfPresent(JSONValue.self, forKey: .value)
        value = (try? c.decodeIfPresent(String.self, forKey: .value))
            ?? decodedValue?.stringValue
            ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
            ?? c.decodeIfPresent(String.self, forKey: .token)
    }
}

public struct RemoteTenantSearchHighlightRange: Decodable, Equatable, Sendable {
    public let field: String
    public let start: Int
    public let length: Int

    enum CodingKeys: String, CodingKey {
        case field
        case start
        case length
    }

    public init(field: String, start: Int, length: Int) {
        self.field = field
        self.start = start
        self.length = length
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? ""
        start = c.decodeLossyIntIfPresent(forKey: .start) ?? 0
        length = c.decodeLossyIntIfPresent(forKey: .length) ?? 0
    }
}

public struct RemoteTenantSearchJumpTarget: Decodable, Equatable, Sendable {
    public let kind: String
    public let channelID: String?
    public let channelType: String?
    public let channelSeq: Int64?
    public let messageID: String?
    public let fileID: String?
    public let detailEndpoint: String?
    public let imUID: String?
    public let userID: String?
    public let peerIMUID: String?

    enum CodingKeys: String, CodingKey {
        case kind
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
        case detailEndpoint = "detail_endpoint"
        case detailEndpointCamel = "detailEndpoint"
        case imUID = "im_uid"
        case imUIDCamel = "imUID"
        case userID = "user_id"
        case userIDCamel = "userId"
        case peerIMUID = "peer_im_uid"
        case peerIMUIDCamel = "peerIMUID"
    }

    public init(
        kind: String,
        channelID: String? = nil,
        channelType: String? = nil,
        channelSeq: Int64? = nil,
        messageID: String? = nil,
        fileID: String? = nil,
        detailEndpoint: String? = nil,
        imUID: String? = nil,
        userID: String? = nil,
        peerIMUID: String? = nil
    ) {
        self.kind = kind
        self.channelID = channelID
        self.channelType = channelType
        self.channelSeq = channelSeq
        self.messageID = messageID
        self.fileID = fileID
        self.detailEndpoint = detailEndpoint
        self.imUID = imUID
        self.userID = userID
        self.peerIMUID = peerIMUID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
            ?? c.decodeIfPresent(String.self, forKey: .channelIDCamel)
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
            ?? c.decodeIfPresent(String.self, forKey: .channelTypeCamel)
        channelSeq = c.decodeLossyInt64IfPresent(forKey: .channelSeq)
            ?? c.decodeLossyInt64IfPresent(forKey: .channelSeqCamel)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
            ?? c.decodeIfPresent(String.self, forKey: .messageIDCamel)
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID)
            ?? c.decodeIfPresent(String.self, forKey: .fileIDCamel)
        detailEndpoint = try c.decodeIfPresent(String.self, forKey: .detailEndpoint)
            ?? c.decodeIfPresent(String.self, forKey: .detailEndpointCamel)
        imUID = try c.decodeIfPresent(String.self, forKey: .imUID)
            ?? c.decodeIfPresent(String.self, forKey: .imUIDCamel)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
            ?? c.decodeIfPresent(String.self, forKey: .userIDCamel)
        peerIMUID = try c.decodeIfPresent(String.self, forKey: .peerIMUID)
            ?? c.decodeIfPresent(String.self, forKey: .peerIMUIDCamel)
    }
}
// WDT_IOS1_DATA_SEARCH_WIRE_FAMILY_20261111_END

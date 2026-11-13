import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteSendResponse: Decodable, Sendable {
    public let message: RemoteMessage

    public init(
        message: RemoteMessage
    ) {
        self.message = message
    }
}

public struct RemoteForwardMessageResponse: Decodable, Sendable {
    public let message: RemoteMessage

    enum CodingKeys: String, CodingKey {
        case message
        case item
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if let message = try container.decodeIfPresent(RemoteMessage.self, forKey: .message) {
                self.message = message
                return
            }
            if let item = try container.decodeIfPresent(RemoteMessage.self, forKey: .item) {
                self.message = item
                return
            }
        }
        self.message = try RemoteMessage(from: decoder)
    }

    public init(
        message: RemoteMessage
    ) {
        self.message = message
    }
}

public struct RemoteTenantFileForwardResponse: Decodable, Sendable {
    public let message: RemoteMessage

    private struct NestedMessage: Decodable {
        let message: RemoteMessage
    }

    private enum CodingKeys: String, CodingKey {
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(NestedMessage.self, forKey: .message),
           !nested.message.messageID.isEmpty {
            message = nested.message
            return
        }
        let direct = try container.decode(RemoteMessage.self, forKey: .message)
        guard !direct.messageID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .message,
                in: container,
                debugDescription: "Forward response message_id is required"
            )
        }
        message = direct
    }

    public init(
        message: RemoteMessage
    ) {
        self.message = message
    }
}

public struct RemoteMessageReport: Decodable, Sendable {
    public let id: String?
    public let reporterUID: String?
    public let reporterName: String?
    public let reporterAvatar: String?
    public let messageID: String?
    public let channelID: String?
    public let channelType: String?
    public let location: String?
    public let senderUID: String?
    public let senderName: String?
    public let senderAvatar: String?
    public let messageText: String?
    public let reason: String?
    public let description: String?
    public let status: String?
    public let createdAt: String?
    public let alreadyReported: Bool
    public let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case reporterUID = "reporter_uid"
        case reporterName = "reporter_name"
        case reporterAvatar = "reporter_avatar"
        case messageID = "message_id"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case location
        case senderUID = "sender_uid"
        case senderName = "sender_name"
        case senderAvatar = "sender_avatar"
        case messageText = "message_text"
        case reason
        case description
        case status
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case alreadyReported = "already_reported"
        case alreadyReportedCamel = "alreadyReported"
        case readOnly = "read_only"
        case readOnlyCamel = "readOnly"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        reporterUID = try c.decodeIfPresent(String.self, forKey: .reporterUID)
        reporterName = try c.decodeIfPresent(String.self, forKey: .reporterName)
        reporterAvatar = try c.decodeIfPresent(String.self, forKey: .reporterAvatar)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
        channelID = try c.decodeIfPresent(String.self, forKey: .channelID)
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        senderUID = try c.decodeIfPresent(String.self, forKey: .senderUID)
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName)
        senderAvatar = try c.decodeIfPresent(String.self, forKey: .senderAvatar)
        messageText = try c.decodeIfPresent(String.self, forKey: .messageText)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .createdAtCamel)
        alreadyReported = c.decodeLossyBoolIfPresent(forKey: .alreadyReported)
            ?? c.decodeLossyBoolIfPresent(forKey: .alreadyReportedCamel)
            ?? false
        readOnly = c.decodeLossyBoolIfPresent(forKey: .readOnly)
            ?? c.decodeLossyBoolIfPresent(forKey: .readOnlyCamel)
            ?? false
    }

    public init(
        id: String?,
        reporterUID: String?,
        reporterName: String?,
        reporterAvatar: String?,
        messageID: String?,
        channelID: String?,
        channelType: String?,
        location: String?,
        senderUID: String?,
        senderName: String?,
        senderAvatar: String?,
        messageText: String?,
        reason: String?,
        description: String?,
        status: String?,
        createdAt: String?,
        alreadyReported: Bool,
        readOnly: Bool
    ) {
        self.id = id
        self.reporterUID = reporterUID
        self.reporterName = reporterName
        self.reporterAvatar = reporterAvatar
        self.messageID = messageID
        self.channelID = channelID
        self.channelType = channelType
        self.location = location
        self.senderUID = senderUID
        self.senderName = senderName
        self.senderAvatar = senderAvatar
        self.messageText = messageText
        self.reason = reason
        self.description = description
        self.status = status
        self.createdAt = createdAt
        self.alreadyReported = alreadyReported
        self.readOnly = readOnly
    }
}

public struct RemoteMessageReportLookupResponse: Decodable, Sendable {
    public let reported: Bool
    public let report: RemoteMessageReport?

    enum CodingKeys: String, CodingKey {
        case reported
        case report
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reported = c.decodeLossyBoolIfPresent(forKey: .reported) ?? false
        report = try c.decodeIfPresent(RemoteMessageReport.self, forKey: .report)
    }

    public init(
        reported: Bool,
        report: RemoteMessageReport?
    ) {
        self.reported = reported
        self.report = report
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

let batchForwardVoiceOwnershipReason = "仅可转发自己发送的语音"


public enum BatchForwardTargetTab: String, Codable, CaseIterable, Sendable {
    case friend
    case group
}

public enum BatchForwardMode: String, Codable, Sendable {
    case separate
}

public struct BatchForwardScope: Equatable, Codable, Sendable {
    public let tenantID: String
    public let actorUID: String
    public let sourceChannelID: String
    public let sourceChannelType: String

    private enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case actorUID = "actor_uid"
        case sourceChannelID = "source_channel_id"
        case sourceChannelType = "source_channel_type"
    }

    public init(tenantID: String,
        actorUID: String,
        sourceChannelID: String,
        sourceChannelType: String) {
        self.tenantID = tenantID
        self.actorUID = actorUID
        self.sourceChannelID = sourceChannelID
        self.sourceChannelType = sourceChannelType
    }
}

public struct BatchForwardMessageSnapshot: Equatable, Codable, Sendable {
    public let messageID: String
    public let sourceChannelID: String
    public let sourceChannelType: String
    public let senderUID: String?
    public let senderProvenance: BatchForwardSenderProvenance
    public let channelSeq: Int64?
    public let createdAtMillis: Int64?
    let historyPage: Int?
    public let clientState: String
    public let contentType: String
    public let kind: String
    public let mediaCategory: String
    public let previewKind: String
    public let nestedSemanticMarkers: [String]
    public let fileName: String
    public let mimeType: String

    public init(
        messageID: String,
        sourceChannelID: String,
        sourceChannelType: String,
        senderUID: String?,
        senderProvenance: BatchForwardSenderProvenance,
        channelSeq: Int64? = nil,
        createdAtMillis: Int64? = nil,
        historyPage: Int? = nil,
        clientState: String = "sent",
        contentType: String = "",
        kind: String = "",
        mediaCategory: String = "",
        previewKind: String = "",
        nestedSemanticMarkers: [String] = [],
        fileName: String = "",
        mimeType: String = ""
    ) {
        self.messageID = messageID
        self.sourceChannelID = sourceChannelID
        self.sourceChannelType = sourceChannelType
        self.senderUID = senderUID
        self.senderProvenance = senderProvenance
        self.channelSeq = channelSeq
        self.createdAtMillis = createdAtMillis
        self.historyPage = historyPage
        self.clientState = clientState
        self.contentType = contentType
        self.kind = kind
        self.mediaCategory = mediaCategory
        self.previewKind = previewKind
        self.nestedSemanticMarkers = nestedSemanticMarkers
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

public enum BatchForwardEligibility: Equatable, Sendable {
    case selectable
    case disabled(String)
}

public struct BatchForwardTarget: Equatable, Codable, Sendable {
    public let channelID: String
    public let channelType: String
    public let displayName: String
    public let searchTerms: [String]

    public init(
        channelID: String,
        channelType: String,
        displayName: String,
        searchTerms: [String] = []
    ) {
        self.channelID = channelID
        self.channelType = channelType
        self.displayName = displayName
        self.searchTerms = searchTerms
    }

    public var tab: BatchForwardTargetTab? {
        switch BatchForwardSemantics.normalized(channelType) {
        case "direct", "friend", "single", "person":
            return .friend
        case "group":
            return .group
        default:
            return nil
        }
    }

    public func canonicalChannelID(actorUID: String) -> String {
        BatchForwardSemantics.canonicalChannelID(
            channelID,
            channelType: channelType,
            actorUID: actorUID
        )
    }

    public func identityKey(actorUID: String) -> String {
        "\(BatchForwardSemantics.canonicalChannelType(channelType))|\(canonicalChannelID(actorUID: actorUID))"
    }
}

public struct BatchForwardTargetCandidate: Identifiable, Equatable, Sendable {
    public let identityKey: String
    public let target: BatchForwardTarget
    public let subtitle: String
    public let avatarSeed: UInt
    public let avatarURL: String
    public let avatarVersion: String
    public let avatarUpdatedAt: String
    public let memberCount: Int?

    public var id: String { identityKey }
    public var isGroup: Bool { target.tab == .group }

    public init(identityKey: String,
        target: BatchForwardTarget,
        subtitle: String,
        avatarSeed: UInt,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        memberCount: Int? = nil) {
        self.identityKey = identityKey
        self.target = target
        self.subtitle = subtitle
        self.avatarSeed = avatarSeed
        self.avatarURL = avatarURL
        self.avatarVersion = avatarVersion
        self.avatarUpdatedAt = avatarUpdatedAt
        self.memberCount = memberCount
    }
}

public enum BatchForwardSemantics {
    private static let strongVoiceMarkers: Set<String> = [
        "voice",
        "voice_clip",
        "voice_message",
        "voice_message_file",
        "voice_note",
        "voicemessage",
        "audio_message",
        "audio_message_file",
        "audio_note",
        "recorded_voice",
        "recording",
        "ptt",
        "push_to_talk",
        "语音",
        "语音消息",
    ]

    private static let blockedKinds: Set<String> = [
        "system",
        "system_message",
        "control",
        "membership",
        "call",
        "call_event",
        "call_control",
        "rtc",
        "rtc_event",
        "merge_forward",
        "merged_forward",
        "forward_bundle",
    ]

    private static let allowedContentMarkers: Set<String> = [
        "text",
        "plain_text",
        "rich_text",
        "image",
        "photo",
        "video",
        "audio",
        "audio_file",
        "music",
        "file",
        "document",
        "attachment",
        "location",
        "contact",
        "card",
        "sticker",
        "emoji",
        "gif",
        "reply",
        "quote",
    ]

    private static let allowedStates: Set<String> = [
        "sent",
        "edited",
        "read",
        "delivered",
    ]

    static public func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    static public func canonicalChannelType(_ value: String) -> String {
        switch normalized(value) {
        case "direct", "friend", "single", "person":
            return "direct"
        case "group":
            return "group"
        default:
            return normalized(value)
        }
    }

    static public func canonicalChannelID(
        _ value: String,
        channelType: String,
        actorUID: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canonicalChannelType(channelType) == "direct" else {
            return trimmed
        }
        let parts = trimmed
            .split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "|" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) {
            return parts.sorted().joined(separator: ":")
        }
        let actor = actorUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !actor.isEmpty,
           trimmed != actor,
           !trimmed.contains(where: { $0 == ":" || $0 == "," || $0 == "|" }) {
            return [actor, trimmed].sorted().joined(separator: ":")
        }
        return trimmed
    }

    private static func containsStrongVoiceMarker(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard !value.isEmpty else {
            return false
        }
        if strongVoiceMarkers.contains(value) {
            return true
        }
        let components = value.split { character in
            character == "." || character == "/" || character == ":" || character == "#"
        }
        return components.contains { strongVoiceMarkers.contains(String($0)) }
    }

    private static func hasLegacyVoiceFileName(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("voice-") || value.hasPrefix("voice_") || value.hasPrefix("voice.")
    }

    private static func containsBlockedMarker(_ raw: String) -> Bool {
        let value = normalized(raw)
        if blockedKinds.contains(value) {
            return true
        }
        let components = value.split { character in
            character == "." || character == "/" || character == ":" || character == "#"
        }
        return components.contains { blockedKinds.contains(String($0)) }
    }

    private static func isAllowedContentMarker(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard !value.isEmpty else {
            return true
        }
        if allowedContentMarkers.contains(value) || containsStrongVoiceMarker(value) {
            return true
        }
        return value.hasPrefix("text/")
            || value.hasPrefix("image/")
            || value.hasPrefix("video/")
            || value.hasPrefix("audio/")
            || value.hasPrefix("application/")
    }

    static func isVoice(_ message: BatchForwardMessageSnapshot) -> Bool {
        let nonKindMarkers = [
            message.contentType,
            message.mediaCategory,
            message.previewKind,
        ] + message.nestedSemanticMarkers
        if nonKindMarkers.contains(where: containsStrongVoiceMarker) {
            return true
        }
        if hasLegacyVoiceFileName(message.fileName) {
            return true
        }

        return containsStrongVoiceMarker(message.kind)
    }

    static public func eligibility(
        of message: BatchForwardMessageSnapshot,
        actorUID: String
    ) -> BatchForwardEligibility {
        let state = normalized(message.clientState)
        guard allowedStates.contains(state) else {
            return .disabled("消息当前不可转发")
        }

        let semanticValues = [
            message.contentType,
            message.kind,
            message.mediaCategory,
            message.previewKind,
        ] + message.nestedSemanticMarkers
        if semanticValues.contains(where: containsBlockedMarker) {
            return .disabled("该消息类型不可转发")
        }
        let primaryContentMarkers = [
            message.contentType,
            message.kind,
            message.mediaCategory,
            message.previewKind,
        ]
        guard primaryContentMarkers.contains(where: { !normalized($0).isEmpty })
                || isVoice(message),
              primaryContentMarkers.allSatisfy(isAllowedContentMarker) else {
            return .disabled("该消息类型不可转发")
        }

        guard isVoice(message) else {
            return .selectable
        }
        guard message.senderProvenance == .authoritativeStored,
              let senderUID = message.senderUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !senderUID.isEmpty,
              senderUID == actorUID else {
            return .disabled(batchForwardVoiceOwnershipReason)
        }
        return .selectable
    }
}

public struct BatchForwardTargetRequest: Equatable, Codable, Sendable {
    public let channelID: String
    public let channelType: String

    private enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelType = "channel_type"
    }

    public init(channelID: String,
        channelType: String) {
        self.channelID = channelID
        self.channelType = channelType
    }
}

public struct BatchForwardRequest: Equatable, Codable, Sendable {
    public let clientBatchID: String
    public let sourceChannelID: String
    public let sourceChannelType: String
    public let sourceMessageIDs: [String]
    public let targets: [BatchForwardTargetRequest]
    public let mode: BatchForwardMode

    private enum CodingKeys: String, CodingKey {
        case clientBatchID = "client_batch_id"
        case sourceChannelID = "source_channel_id"
        case sourceChannelType = "source_channel_type"
        case sourceMessageIDs = "source_message_ids"
        case targets
        case mode
    }

    public init(clientBatchID: String,
        sourceChannelID: String,
        sourceChannelType: String,
        sourceMessageIDs: [String],
        targets: [BatchForwardTargetRequest],
        mode: BatchForwardMode) {
        self.clientBatchID = clientBatchID
        self.sourceChannelID = sourceChannelID
        self.sourceChannelType = sourceChannelType
        self.sourceMessageIDs = sourceMessageIDs
        self.targets = targets
        self.mode = mode
    }
}

public struct BatchForwardSubmitCommand: Equatable, Sendable {
    public let request: BatchForwardRequest
    public let headers: [String: String]

    public init(request: BatchForwardRequest,
        headers: [String: String]) {
        self.request = request
        self.headers = headers
    }
}

public struct BatchForwardCreatedMessage: Equatable, Codable, Sendable {
    public let sourceOrdinal: Int
    public let sourceMessageID: String
    public let messageID: String

    private enum CodingKeys: String, CodingKey {
        case sourceOrdinal = "source_ordinal"
        case sourceMessageID = "source_message_id"
        case messageID = "message_id"
    }
}

public struct BatchForwardTargetResult: Equatable, Codable, Sendable {
    public let targetOrdinal: Int
    public let channelID: String
    public let channelType: String
    public let messages: [BatchForwardCreatedMessage]

    private enum CodingKeys: String, CodingKey {
        case targetOrdinal = "target_ordinal"
        case channelID = "channel_id"
        case channelType = "channel_type"
        case messages
    }

    public init(targetOrdinal: Int,
        channelID: String,
        channelType: String,
        messages: [BatchForwardCreatedMessage]) {
        self.targetOrdinal = targetOrdinal
        self.channelID = channelID
        self.channelType = channelType
        self.messages = messages
    }
}

public struct BatchForwardCommittedResult: Equatable, Codable, Sendable {
    public let contractVersion: Int
    public let batchID: String
    public let clientBatchID: String
    public let sourceCount: Int
    public let targetCount: Int
    public let createdCount: Int
    public let state: String
    public let idempotentReplay: Bool
    public let authoritativeSourceMessageIDs: [String]
    public let targets: [BatchForwardTargetResult]

    private enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case batchID = "batch_id"
        case clientBatchID = "client_batch_id"
        case sourceCount = "source_count"
        case targetCount = "target_count"
        case createdCount = "created_count"
        case state
        case idempotentReplay = "idempotent_replay"
        case authoritativeSourceMessageIDs = "authoritative_source_message_ids"
        case targets
    }

    public var serverCreatedMessageIDs: [String] {
        targets.flatMap(\.messages).map(\.messageID)
    }

    public init(contractVersion: Int,
        batchID: String,
        clientBatchID: String,
        sourceCount: Int,
        targetCount: Int,
        createdCount: Int,
        state: String,
        idempotentReplay: Bool,
        authoritativeSourceMessageIDs: [String],
        targets: [BatchForwardTargetResult]) {
        self.contractVersion = contractVersion
        self.batchID = batchID
        self.clientBatchID = clientBatchID
        self.sourceCount = sourceCount
        self.targetCount = targetCount
        self.createdCount = createdCount
        self.state = state
        self.idempotentReplay = idempotentReplay
        self.authoritativeSourceMessageIDs = authoritativeSourceMessageIDs
        self.targets = targets
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

public enum BatchForwardSubmissionPhase: Equatable, Sendable {
    case idle
    case submitting(clientBatchID: String)
    case retryableFailure(String?)
    case uncertain(String?)
    case committed(batchID: String)
}

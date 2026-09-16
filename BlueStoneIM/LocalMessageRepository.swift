import Foundation

struct LocalMessageSessionTicket: Hashable, Sendable {
    let scopeHash: String
    let sessionGeneration: UInt64
    let coordinatorEpoch: UInt64
}

enum LocalMessageProjectionSource: String, Sendable {
    case legacySnapshot = "legacy_snapshot"
    case coldStart = "cold_start"
    case conversationSync = "conversation_sync"
    case history = "history"
    case realtime = "realtime"
    case localMutation = "local_mutation"
    case outbox = "outbox"
    case serverAcknowledgement = "server_ack"
}

struct LocalMessageConversationSnapshot: Sendable {
    let metadata: CachedConversation
    let messages: [CachedMessage]
    let channelID: String
    let channelType: String
    let currentActorID: String
    let requiresServerRevalidation: Bool

    init(
        conversation: Conversation,
        channelID: String,
        channelType: String,
        currentActorID: String,
        projectedMessages: [ChatMessage]? = nil,
        requiresServerRevalidation: Bool = false
    ) {
        metadata = CachedConversation(conversation: conversation, messageLimit: 0)
        messages = (projectedMessages ?? conversation.messages).map(CachedMessage.init)
        self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.currentActorID = currentActorID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requiresServerRevalidation = requiresServerRevalidation
    }
}

struct LocalMessageLoadMetrics: Equatable, Sendable {
    let openMilliseconds: Int
    let queryMilliseconds: Int
    let conversationCount: Int
    let messageCount: Int
}

struct LocalMessageDatabaseLoadResult: Sendable {
    let ticket: LocalMessageSessionTicket
    let conversations: [CachedConversation]
    let profileContactProjection: LocalProfileContactProjection?
    let pendingOutbox: [LocalMessageRecoveredOutbox]
    let metrics: LocalMessageLoadMetrics
}

struct LocalMessageMergeMetrics: Equatable, Sendable {
    var inserted = 0
    var updated = 0
    var duplicate = 0
    var conflict = 0
    var gapCount = 0
}

struct LocalMessageAttachmentIntent: Sendable {
    let data: Data?
    let fileURL: URL?
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    let checksum: String

    init(data: Data, fileName: String, mimeType: String, sizeBytes: Int64, checksum: String) {
        self.data = data
        fileURL = nil
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.checksum = checksum
    }

    init(fileURL: URL, fileName: String, mimeType: String, sizeBytes: Int64) {
        data = nil
        self.fileURL = fileURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        checksum = ""
    }
}

struct LocalMessageOutgoingIntent: Sendable {
    let conversation: LocalMessageConversationSnapshot
    let message: CachedMessage
    let operationKind: String
    let attachment: LocalMessageAttachmentIntent?
}

struct LocalMessageRecoveredOutbox: Sendable {
    let clientMessageID: String
    let conversationID: String
    let channelID: String
    let channelType: String
    let operationKind: String
    let state: String
    let attemptCount: Int
    let nextAttemptAt: TimeInterval?
    let requiresUserInitiatedReplay: Bool
    let message: CachedMessage
    let attachmentRelativePath: String?
    let attachmentFileName: String?
    let attachmentMimeType: String?
    let attachmentSizeBytes: Int64?
    let attachmentFileID: String?
    let attachmentPhase: String?
}

enum LocalMessageOutboxReplayTrigger: Equatable, Sendable {
    case automatic
    case userInitiated
}

struct LocalMessageOutboxReplayPolicy: Equatable, Sendable {
    static let standard = LocalMessageOutboxReplayPolicy(
        maximumAutomaticAttempts: 5,
        initialRetryDelay: 2,
        maximumRetryDelay: 5 * 60
    )

    let maximumAutomaticAttempts: Int
    let initialRetryDelay: TimeInterval
    let maximumRetryDelay: TimeInterval

    func retryDelay(afterAttempt attemptCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter {
            return min(max(0, retryAfter), maximumRetryDelay)
        }
        let exponent = min(max(0, attemptCount - 1), 16)
        return min(initialRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }
}

struct LocalMessageAckRetryPolicy: Equatable, Sendable {
    static let standard = LocalMessageAckRetryPolicy(
        maximumAutomaticAttempts: 5,
        initialRetryDelay: 1,
        maximumRetryDelay: 60
    )

    let maximumAutomaticAttempts: Int
    let initialRetryDelay: TimeInterval
    let maximumRetryDelay: TimeInterval

    func retryDelay(afterAttempt attemptCount: Int) -> TimeInterval {
        let exponent = min(max(0, attemptCount - 1), 16)
        return min(initialRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }
}

struct LocalMessagePendingAck: Equatable, Sendable {
    let channelID: String
    let type: String
    let desiredSeq: Int64
    let inflightSeq: Int64
    let confirmedSeq: Int64
    let attemptCount: Int
    let retryAt: TimeInterval?
}

struct LocalMessageOutgoingAuthority: Equatable, Sendable {
    let clientMessageID: String
    let state: String
    let authoritativeMessageID: String?
    let authoritativeChannelSeq: Int64?

    var isAcknowledged: Bool {
        state == LocalMessageOutboxState.acknowledged.rawValue
            && !(authoritativeMessageID ?? "").isEmpty
            && (authoritativeChannelSeq ?? 0) > 0
    }
}

struct LocalMessageSearchResult: Sendable {
    let conversationID: String
    let message: CachedMessage
}

struct LocalMessageDatabaseDiagnostics: Equatable, Sendable {
    let scopeHash: String
    let schemaVersion: Int
    let journalMode: String
    let quickCheck: String
    let writerFence: Int64
    let backupExcluded: Bool
    let conversationCount: Int
    let messageCount: Int
    let outboxCount: Int
    let gapCount: Int
}

enum LocalMessageOutboxState: String, Sendable {
    case stagingAttachment = "staging_attachment"
    case ready
    case sending
    case awaitingAcknowledgement = "awaiting_ack"
    case uncertain
    case retryWait = "retry_wait"
    case failedPermanent = "failed_permanent"
    case acknowledged = "acked"
    case cancelled

    var isRecoverable: Bool {
        switch self {
        case .stagingAttachment, .ready, .sending, .awaitingAcknowledgement, .uncertain, .retryWait:
            return true
        case .failedPermanent, .acknowledged, .cancelled:
            return false
        }
    }
}

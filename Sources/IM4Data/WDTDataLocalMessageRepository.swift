// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation
import IM4Domain // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

public struct LocalMessageSessionTicket: Hashable, Sendable {
    public let scopeHash: String
    public let sessionGeneration: UInt64
    public let coordinatorEpoch: UInt64

    public init(scopeHash: String, sessionGeneration: UInt64, coordinatorEpoch: UInt64) {
        self.scopeHash = scopeHash
        self.sessionGeneration = sessionGeneration
        self.coordinatorEpoch = coordinatorEpoch
    }
}

public enum LocalMessageProjectionSource: String, Sendable {
    case legacySnapshot = "legacy_snapshot"
    case coldStart = "cold_start"
    case conversationSync = "conversation_sync"
    case history = "history"
    case realtime = "realtime"
    case localMutation = "local_mutation"
    case outbox = "outbox"
    case serverAcknowledgement = "server_ack"
}

public struct LocalMessageConversationSnapshot: Sendable {
    public let metadata: CachedConversation
    public let messages: [CachedMessage]
    public let channelID: String
    public let channelType: String
    public let currentActorID: String
    public let requiresServerRevalidation: Bool

    public init(
        conversation: ConversationMessageSnapshot,
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

public struct LocalMessageLoadMetrics: Equatable, Sendable {
    public let openMilliseconds: Int
    public let queryMilliseconds: Int
    public let conversationCount: Int
    public let messageCount: Int

    public init(openMilliseconds: Int, queryMilliseconds: Int, conversationCount: Int, messageCount: Int) {
        self.openMilliseconds = openMilliseconds
        self.queryMilliseconds = queryMilliseconds
        self.conversationCount = conversationCount
        self.messageCount = messageCount
    }
}

public struct LocalMessageDatabaseLoadResult: Sendable {
    public let ticket: LocalMessageSessionTicket
    public let conversations: [CachedConversation]
    public let profileContactProjection: LocalProfileContactProjection?
    public let pendingOutbox: [LocalMessageRecoveredOutbox]
    public let metrics: LocalMessageLoadMetrics

    public init(ticket: LocalMessageSessionTicket, conversations: [CachedConversation], profileContactProjection: LocalProfileContactProjection?, pendingOutbox: [LocalMessageRecoveredOutbox], metrics: LocalMessageLoadMetrics) {
        self.ticket = ticket
        self.conversations = conversations
        self.profileContactProjection = profileContactProjection
        self.pendingOutbox = pendingOutbox
        self.metrics = metrics
    }
}

public struct LocalMessageMergeMetrics: Equatable, Sendable {
    public var inserted = 0
    public var updated = 0
    public var duplicate = 0
    public var conflict = 0
    public var gapCount = 0
}

public struct LocalMessageAttachmentIntent: Sendable {
    public let data: Data?
    public let fileURL: URL?
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let checksum: String

    public init(data: Data, fileName: String, mimeType: String, sizeBytes: Int64, checksum: String) {
        self.data = data
        fileURL = nil
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.checksum = checksum
    }

    public init(fileURL: URL, fileName: String, mimeType: String, sizeBytes: Int64) {
        data = nil
        self.fileURL = fileURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        checksum = ""
    }
}

public struct LocalMessageOutgoingIntent: Sendable {
    public let conversation: LocalMessageConversationSnapshot
    public let message: CachedMessage
    public let operationKind: String
    public let attachment: LocalMessageAttachmentIntent?

    public init(conversation: LocalMessageConversationSnapshot, message: CachedMessage, operationKind: String, attachment: LocalMessageAttachmentIntent?) {
        self.conversation = conversation
        self.message = message
        self.operationKind = operationKind
        self.attachment = attachment
    }
}

public struct LocalMessageRecoveredOutbox: Sendable {
    public let clientMessageID: String
    public let conversationID: String
    public let channelID: String
    public let channelType: String
    public let operationKind: String
    public let state: String
    public let attemptCount: Int
    public let nextAttemptAt: TimeInterval?
    public let requiresUserInitiatedReplay: Bool
    public let message: CachedMessage
    public let attachmentRelativePath: String?
    public let attachmentFileName: String?
    public let attachmentMimeType: String?
    public let attachmentSizeBytes: Int64?
    public let attachmentFileID: String?
    public let attachmentPhase: String?

    public init(clientMessageID: String, conversationID: String, channelID: String, channelType: String, operationKind: String, state: String, attemptCount: Int, nextAttemptAt: TimeInterval?, requiresUserInitiatedReplay: Bool, message: CachedMessage, attachmentRelativePath: String?, attachmentFileName: String?, attachmentMimeType: String?, attachmentSizeBytes: Int64?, attachmentFileID: String?, attachmentPhase: String?) {
        self.clientMessageID = clientMessageID
        self.conversationID = conversationID
        self.channelID = channelID
        self.channelType = channelType
        self.operationKind = operationKind
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.requiresUserInitiatedReplay = requiresUserInitiatedReplay
        self.message = message
        self.attachmentRelativePath = attachmentRelativePath
        self.attachmentFileName = attachmentFileName
        self.attachmentMimeType = attachmentMimeType
        self.attachmentSizeBytes = attachmentSizeBytes
        self.attachmentFileID = attachmentFileID
        self.attachmentPhase = attachmentPhase
    }
}

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
public enum LocalMessageSendAdmission: Sendable {
    case send(knownUnsent: Bool)
    case deferred
    case confirmationRequired
}

/// Serializes revocation with the synchronous SQLite commit and staged-file cleanup.
public final class LocalMessageConfirmationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    public init() {}

    public func revoke() {
        lock.withLock { revoked = true }
    }

    public func withCurrent<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            guard !revoked else { throw CancellationError() }
            return try operation()
        }
    }
}

public struct LocalMessageHistoryConfirmation: Sendable {
    let route: LocalMessageConfirmationPermit
    let storage: LocalMessageConfirmationPermit
    let cancellation: LocalMessageConfirmationPermit

    public init(route: LocalMessageConfirmationPermit, storage: LocalMessageConfirmationPermit,
                cancellation: LocalMessageConfirmationPermit) {
        self.route = route
        self.storage = storage
        self.cancellation = cancellation
    }

    func withCurrent<Value>(_ operation: () throws -> Value) throws -> Value {
        try route.withCurrent {
            try storage.withCurrent {
                try cancellation.withCurrent(operation)
            }
        }
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

public enum LocalMessageOutboxReplayTrigger: Equatable, Sendable {
    case automatic
    case userInitiated
}

public struct LocalMessageOutboxReplayPolicy: Equatable, Sendable {
    public static let standard = LocalMessageOutboxReplayPolicy(
        maximumAutomaticAttempts: 5,
        initialRetryDelay: 2,
        maximumRetryDelay: 5 * 60
    )

    public let maximumAutomaticAttempts: Int
    public let initialRetryDelay: TimeInterval
    public let maximumRetryDelay: TimeInterval

    public func retryDelay(afterAttempt attemptCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter {
            return min(max(0, retryAfter), maximumRetryDelay)
        }
        let exponent = min(max(0, attemptCount - 1), 16)
        return min(initialRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }

    public init(maximumAutomaticAttempts: Int, initialRetryDelay: TimeInterval, maximumRetryDelay: TimeInterval) {
        self.maximumAutomaticAttempts = maximumAutomaticAttempts
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }
}

public struct LocalMessageAckRetryPolicy: Equatable, Sendable {
    public static let standard = LocalMessageAckRetryPolicy(
        maximumAutomaticAttempts: 5,
        initialRetryDelay: 1,
        maximumRetryDelay: 60
    )

    public let maximumAutomaticAttempts: Int
    public let initialRetryDelay: TimeInterval
    public let maximumRetryDelay: TimeInterval

    public func retryDelay(afterAttempt attemptCount: Int) -> TimeInterval {
        let exponent = min(max(0, attemptCount - 1), 16)
        return min(initialRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }

    public init(maximumAutomaticAttempts: Int, initialRetryDelay: TimeInterval, maximumRetryDelay: TimeInterval) {
        self.maximumAutomaticAttempts = maximumAutomaticAttempts
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }
}

public struct LocalMessagePendingAck: Equatable, Sendable {
    public let channelID: String
    public let type: String
    public let desiredSeq: Int64
    public let inflightSeq: Int64
    public let confirmedSeq: Int64
    public let attemptCount: Int
    public let retryAt: TimeInterval?

    public init(channelID: String, type: String, desiredSeq: Int64, inflightSeq: Int64, confirmedSeq: Int64, attemptCount: Int, retryAt: TimeInterval?) {
        self.channelID = channelID
        self.type = type
        self.desiredSeq = desiredSeq
        self.inflightSeq = inflightSeq
        self.confirmedSeq = confirmedSeq
        self.attemptCount = attemptCount
        self.retryAt = retryAt
    }
}

public struct LocalMessageOutgoingAuthority: Equatable, Sendable {
    public let clientMessageID: String
    public let state: String
    public let authoritativeMessageID: String?
    public let authoritativeChannelSeq: Int64?

    public var isAcknowledged: Bool {
        state == LocalMessageOutboxState.acknowledged.rawValue
            && !(authoritativeMessageID ?? "").isEmpty
            && (authoritativeChannelSeq ?? 0) > 0
    }

    public init(clientMessageID: String, state: String, authoritativeMessageID: String?, authoritativeChannelSeq: Int64?) {
        self.clientMessageID = clientMessageID
        self.state = state
        self.authoritativeMessageID = authoritativeMessageID
        self.authoritativeChannelSeq = authoritativeChannelSeq
    }
}

public struct LocalMessageSearchResult: Sendable {
    public let conversationID: String
    public let message: CachedMessage

    public init(conversationID: String, message: CachedMessage) {
        self.conversationID = conversationID
        self.message = message
    }
}

public struct LocalMessageDatabaseDiagnostics: Equatable, Sendable {
    public let scopeHash: String
    public let schemaVersion: Int
    public let journalMode: String
    public let quickCheck: String
    public let writerFence: Int64
    public let backupExcluded: Bool
    public let conversationCount: Int
    public let messageCount: Int
    public let outboxCount: Int
    public let gapCount: Int

    public init(scopeHash: String, schemaVersion: Int, journalMode: String, quickCheck: String, writerFence: Int64, backupExcluded: Bool, conversationCount: Int, messageCount: Int, outboxCount: Int, gapCount: Int) {
        self.scopeHash = scopeHash
        self.schemaVersion = schemaVersion
        self.journalMode = journalMode
        self.quickCheck = quickCheck
        self.writerFence = writerFence
        self.backupExcluded = backupExcluded
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.outboxCount = outboxCount
        self.gapCount = gapCount
    }
}

public enum LocalMessageOutboxState: String, Sendable {
    case stagingAttachment = "staging_attachment"
    case ready
    case sending
    case awaitingAcknowledgement = "awaiting_ack"
    case uncertain
    case confirmationRequired = "confirmation_required" // WDT_IOS1_HTTP_ROUTE_V5_20261113
    case retryWait = "retry_wait"
    case failedPermanent = "failed_permanent"
    case acknowledged = "acked"
    case cancelled

    public var isRecoverable: Bool {
        switch self {
        case .stagingAttachment, .ready, .sending, .awaitingAcknowledgement, .uncertain, .confirmationRequired, .retryWait:
            return true
        case .failedPermanent, .acknowledged, .cancelled:
            return false
        }
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_DATA_MODULE_PROTOTYPE_20261110_END

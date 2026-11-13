import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

public extension ConversationStore {
    public struct MessageSyncWindow: Equatable, Sendable {
        public let afterSeq: Int64
        public let limit: Int

        public init(afterSeq: Int64, limit: Int) {
            self.afterSeq = afterSeq
            self.limit = limit
        }
    }

    public enum MessageSyncPlan: Equatable, Sendable {
        case sidecarsOnly
        case remoteHistory(historyKey: String, windows: [MessageSyncWindow])
    }

    typealias MessageWindowRetention = IM4Stores.MessageWindowRetention // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110

    public struct MessageSidecarSyncKeyContext: Equatable, Sendable {
        public let tenantID: String
        public let imUID: String
        public let channelID: String
        public let channelType: String
        public let normalizedChannelID: String
        public let suffix: String

        public init(
            tenantID: String,
            imUID: String,
            channelID: String,
            channelType: String,
            normalizedChannelID: String,
            suffix: String
        ) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.normalizedChannelID = normalizedChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.suffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var syncKey: String {
            [tenantID, imUID, channelType, normalizedChannelID, suffix]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    public struct ReadReceiptSidecarSyncTarget: Equatable, Sendable {
        public let channelID: String
        public let channelType: String

        public init(channelID: String, channelType: String) {
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public struct ConversationReadStateKeyContext: Equatable, Sendable {
        public let channelID: String
        public let channelType: String
        public let normalizedChannelID: String

        public init(channelID: String, channelType: String, normalizedChannelID: String) {
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.normalizedChannelID = normalizedChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var syncKey: String {
            "\(channelType)|\(normalizedChannelID)"
        }
    }

    public struct ReadWatermarkScope: Equatable, Hashable, Sendable {
        public let tenantID: String
        public let imUID: String
        public let appID: String
        public let channelID: String
        public let channelType: String

        public init?(
            tenantID: String,
            imUID: String,
            appID: String,
            channelID: String,
            channelType: String
        ) {
            let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedIMUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedTenantID.isEmpty,
                  !normalizedIMUID.isEmpty,
                  !normalizedAppID.isEmpty,
                  !normalizedChannelID.isEmpty,
                  ["direct", "group", "system"].contains(normalizedChannelType) else {
                return nil
            }
            self.tenantID = normalizedTenantID
            self.imUID = normalizedIMUID
            self.appID = normalizedAppID
            self.channelID = normalizedChannelID
            self.channelType = normalizedChannelType
        }

        public var storageKey: String {
            [tenantID, imUID, appID, channelType, channelID].joined(separator: "\u{0}")
        }

        public var readStateKey: String {
            "\(channelType)|\(channelID)"
        }
    }

    public struct ReadWatermark: Equatable, Sendable {
        public let eventID: String
        public let scope: ReadWatermarkScope
        public let lastReadSeq: Int64
        public let occurredAt: String

        public init?(
            eventID: String,
            tenantID: String,
            imUID: String,
            appID: String,
            channelID: String,
            channelType: String,
            lastReadSeq: Int64,
            occurredAt: String = ""
        ) {
            guard lastReadSeq > 0,
                  let scope = ReadWatermarkScope(
                    tenantID: tenantID,
                    imUID: imUID,
                    appID: appID,
                    channelID: channelID,
                    channelType: channelType
                  ) else {
                return nil
            }
            self.eventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scope = scope
            self.lastReadSeq = lastReadSeq
            self.occurredAt = occurredAt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public struct ConversationHistoryKeyContext: Equatable, Sendable {
        public let tenantID: String
        public let imUID: String
        public let conversationID: String

        public init(tenantID: String, imUID: String, conversationID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var historyKey: String {
            [tenantID, imUID, conversationID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    public struct PinnedMessagesRefreshKeyContext: Equatable, Sendable {
        public let tenantID: String
        public let imUID: String
        public let conversationID: String
        public let channelID: String

        public init(tenantID: String, imUID: String, conversationID: String, channelID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var refreshKey: String {
            [tenantID, imUID, conversationID, channelID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    public struct OlderHistoryAvailabilityTarget: Equatable, Sendable {
        public let historyKey: String
        public let conversationID: String
        public let oldestSeq: Int64

        public init(historyKey: String, conversationID: String, oldestSeq: Int64) {
            self.historyKey = historyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.oldestSeq = max(0, oldestSeq)
        }
    }

    public enum OlderHistoryAvailabilityPlan: Equatable, Sendable {
        case available(OlderHistoryAvailabilityTarget)
        case reachedStart(historyKey: String, conversationID: String)
        case unavailable(historyKey: String, conversationID: String)
    }

    public struct NewerHistoryAvailabilityTarget: Equatable, Sendable {
        public let historyKey: String
        public let conversationID: String
        public let afterSeq: Int64
        public let latestKnownSeq: Int64
        public let limit: Int

        public init(historyKey: String, conversationID: String, afterSeq: Int64, latestKnownSeq: Int64, limit: Int) {
            self.historyKey = historyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.afterSeq = max(0, afterSeq)
            self.latestKnownSeq = max(0, latestKnownSeq)
            self.limit = max(1, limit)
        }
    }

    public struct ConversationPollingPlan: Equatable, Sendable {
        public let conversationID: String
        public let historyKey: String
        public let shouldPollActiveConversation: Bool
        public let isMessageSyncInFlight: Bool

        public init(
            conversationID: String,
            historyKey: String,
            shouldPollActiveConversation: Bool,
            isMessageSyncInFlight: Bool
        ) {
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.historyKey = historyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.shouldPollActiveConversation = shouldPollActiveConversation
            self.isMessageSyncInFlight = isMessageSyncInFlight
        }

        public var shouldPoll: Bool {
            shouldPollActiveConversation && !isMessageSyncInFlight
        }
    }

    public struct ActiveConversationScopedStateKeyContext: Equatable, Sendable {
        public let tenantID: String
        public let imUID: String
        public let conversationID: String

        public init(tenantID: String, imUID: String, conversationID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var scope: String {
            [tenantID, imUID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }

        public var stateKey: String {
            "\(scope)|\(conversationID)"
        }
    }

    public struct ReadAckCommand: Equatable, Sendable {
        public let syncKey: String
        public let targetSeq: Int64?

        public init(syncKey: String, targetSeq: Int64? = nil) {
            self.syncKey = syncKey
            if let targetSeq, targetSeq > 0 {
                self.targetSeq = targetSeq
            } else {
                self.targetSeq = nil
            }
        }
    }

    public enum ReadAckSyncPlan: Equatable, Sendable {
        case clearLocally(ReadAckCommand)
        case remoteAck(ReadAckCommand)
        case queue(ReadAckCommand)
        case skip(ReadAckCommand, reason: String)
    }

    public struct MessageReceiptsSyncCommand: Equatable, Sendable {
        public let syncKey: String
        public let channelID: String
        public let channelType: String
        public let afterSeq: Int64
        public let receiptType: String
        public let limit: Int

        public init(
            syncKey: String,
            channelID: String,
            channelType: String,
            afterSeq: Int64 = 0,
            receiptType: String = "read",
            limit: Int = 100
        ) {
            self.syncKey = syncKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines)
            self.afterSeq = max(0, afterSeq)
            self.receiptType = receiptType.trimmingCharacters(in: .whitespacesAndNewlines)
            self.limit = max(1, limit)
        }
    }

    public struct MessageReceiptsSyncClaim: Equatable, Sendable {
        public let syncKey: String
        public let generation: UInt64

        public init(syncKey: String, generation: UInt64) {
            self.syncKey = syncKey
            self.generation = generation
        }
    }

    public struct PendingDirectReadWindow: Sendable {
        public struct Identity: Equatable, Sendable {
            public let sequence: Int64
            public let senderID: String

            public init(sequence: Int64, senderID: String) {
                self.sequence = sequence
                self.senderID = senderID
            }
        }
        public let conversationID: String
        public let messages: [String: Identity]
        public let sequences: [Int64]

        public func afterSequence(through watermark: Int64 = 0) -> Int64? {
            sequences.first(where: { $0 > watermark }).map { $0 - 1 }
        }

        public init(conversationID: String, messages: [String: Identity], sequences: [Int64]) {
            self.conversationID = conversationID
            self.messages = messages
            self.sequences = sequences
        }
    }

    public enum MessageReceiptsSyncPlan: Equatable, Sendable {
        case sync(MessageReceiptsSyncCommand)
        case skip(MessageReceiptsSyncCommand, reason: String)
    }

    public struct MessageExtrasSyncCommand: Equatable, Sendable {
        public let syncKey: String
        public let channelID: String
        public let channelType: String
        public let afterVersion: Int64
        public let limit: Int

        public init(
            syncKey: String,
            channelID: String,
            channelType: String,
            afterVersion: Int64 = 0,
            limit: Int = 100
        ) {
            self.syncKey = syncKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines)
            self.afterVersion = max(0, afterVersion)
            self.limit = max(1, limit)
        }
    }

    public enum MessageExtrasSyncPlan: Equatable, Sendable {
        case sync(MessageExtrasSyncCommand)
        case skip(MessageExtrasSyncCommand, reason: String)
    }

}

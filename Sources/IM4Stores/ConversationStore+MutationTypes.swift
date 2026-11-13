import Foundation
import IM4Domain
import IM4Data

public extension ConversationStore {
    public struct HistoryPrefetchCandidate: Sendable {
        public let remote: RemoteConversation
        public let channelID: String
        public let local: ConversationMessageSnapshot?
        public let isActive: Bool
        public let latestSeq: Int64
        public let sortTimestamp: TimeInterval
        public let logID: String

        public init(remote: RemoteConversation, channelID: String, local: ConversationMessageSnapshot?, isActive: Bool, latestSeq: Int64, sortTimestamp: TimeInterval, logID: String) {
            self.remote = remote
            self.channelID = channelID
            self.local = local
            self.isActive = isActive
            self.latestSeq = latestSeq
            self.sortTimestamp = sortTimestamp
            self.logID = logID
        }
    }

    public struct HistoryPrefetchTarget: Sendable {
        public let remote: RemoteConversation
        public let channelID: String
        public let reason: String
        public let latestSeq: Int64
        public let sortTimestamp: TimeInterval
        public let logID: String

        public var summaryFragment: String {
            "\(logID)#seq\(latestSeq)#ts\(Int(sortTimestamp))#\(reason)"
        }

        public init(remote: RemoteConversation, channelID: String, reason: String, latestSeq: Int64, sortTimestamp: TimeInterval, logID: String) {
            self.remote = remote
            self.channelID = channelID
            self.reason = reason
            self.latestSeq = latestSeq
            self.sortTimestamp = sortTimestamp
            self.logID = logID
        }
    }

    public struct HistoryPrefetchFetchCommand: Sendable {
        public let remote: RemoteConversation
        public let channelID: String
        public let apiChannelID: String
        public let channelType: String
        public let afterSeq: Int64
        public let limit: Int
        public let reason: String
        public let summaryFragment: String

        public init(remote: RemoteConversation, channelID: String, apiChannelID: String, channelType: String, afterSeq: Int64, limit: Int, reason: String, summaryFragment: String) {
            self.remote = remote
            self.channelID = channelID
            self.apiChannelID = apiChannelID
            self.channelType = channelType
            self.afterSeq = afterSeq
            self.limit = limit
            self.reason = reason
            self.summaryFragment = summaryFragment
        }
    }

    public struct HistoryPrefetchExecutionPlan: Sendable {
        public let commands: [HistoryPrefetchFetchCommand]
        public let maxConcurrent: Int

        public var targetSummary: String {
            commands.map(\.summaryFragment)
                .joined(separator: ",")
        }

        public var batches: [[HistoryPrefetchFetchCommand]] {
            guard !commands.isEmpty else { return [] }
            return stride(from: 0, to: commands.count, by: maxConcurrent).map { startIndex in
                Array(commands[startIndex..<min(startIndex + maxConcurrent, commands.count)])
            }
        }

        public init(commands: [HistoryPrefetchFetchCommand], maxConcurrent: Int) {
            self.commands = commands
            self.maxConcurrent = maxConcurrent
        }
    }

    public struct HistoryPrefetchReadReceiptBackfillTarget: Equatable, Sendable {
        public let channelID: String
        public let channelType: String

        public init(channelID: String, channelType: String) {
            self.channelID = channelID
            self.channelType = channelType
        }
    }

    public struct MappedRemoteMessage: Sendable { // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        public let remote: RemoteMessage
        public let message: ChatMessage
        public let clientMessageIDs: Set<String>
        public let isRemoteFromCurrentUser: Bool
        public let matchedLocalID: String?

        public init(remote: RemoteMessage, message: ChatMessage, clientMessageIDs: Set<String>, isRemoteFromCurrentUser: Bool, matchedLocalID: String?) {
            self.remote = remote
            self.message = message
            self.clientMessageIDs = clientMessageIDs
            self.isRemoteFromCurrentUser = isRemoteFromCurrentUser
            self.matchedLocalID = matchedLocalID
        }
    }

    public struct PendingLocalMessageFinalization: Sendable { // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        public let localID: String
        public let remoteMessage: ChatMessage

        public init(localID: String, remoteMessage: ChatMessage) {
            self.localID = localID
            self.remoteMessage = remoteMessage
        }
    }

    public struct ConfirmedLocalMessageReplacement: Sendable {
        public let previousMessage: ChatMessage
        public let confirmedMessage: ChatMessage

        public init(previousMessage: ChatMessage, confirmedMessage: ChatMessage) {
            self.previousMessage = previousMessage
            self.confirmedMessage = confirmedMessage
        }
    }

    public struct PinnedMessageSnapshotEntry: Sendable {
        public let messageID: String
        public let status: String
        public let message: ChatMessage

        public init(messageID: String, status: String, message: ChatMessage) {
            self.messageID = messageID
            self.status = status
            self.message = message
        }
    }

    public struct HistoryVisibilityBoundary: Equatable, Sendable {
        public let fromSeq: Int64
        public let limited: Bool
        public let confirmed: Bool

        public init(fromSeq: Int64, limited: Bool, confirmed: Bool = true) {
            self.fromSeq = max(1, fromSeq)
            self.limited = limited
            self.confirmed = confirmed
        }

        public var isRestrictive: Bool {
            limited || fromSeq > 1
        }
    }

    public struct ConversationSelectionRequestToken: Equatable, Sendable {
        public let scope: String
        public let conversationID: String
        public let epoch: UInt64

        public init(scope: String, conversationID: String, epoch: UInt64) {
            self.scope = scope
            self.conversationID = conversationID
            self.epoch = epoch
        }
    }

    public struct RemoteConversationMergeEntry: Sendable {
        public let channelID: String
        public let remote: RemoteConversation
        public let conversation: ConversationMessageSnapshot

        public init(channelID: String, remote: RemoteConversation, conversation: ConversationMessageSnapshot) {
            self.channelID = channelID
            self.remote = remote
            self.conversation = conversation
        }
    }

    public struct RemoteConversationSoundCandidate: Sendable {
        public let previous: ConversationMessageSnapshot
        public let remote: RemoteConversation
        public let mapped: ConversationMessageSnapshot

        public init(previous: ConversationMessageSnapshot, remote: RemoteConversation, mapped: ConversationMessageSnapshot) {
            self.previous = previous
            self.remote = remote
            self.mapped = mapped
        }
    }

    public struct MergedRemoteConversationsResult: Sendable {
        public let conversations: [ConversationMessageSnapshot]
        public let soundCandidates: [RemoteConversationSoundCandidate]

        public init(conversations: [ConversationMessageSnapshot], soundCandidates: [RemoteConversationSoundCandidate]) {
            self.conversations = conversations
            self.soundCandidates = soundCandidates
        }
    }

    public struct MergedRemoteMessagesResult: Sendable { // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        public let messages: [ChatMessage]
        public let latestMessage: ChatMessage?
        public let incomingRealtimeMessages: [ChatMessage]
        public let latestKnownSeq: Int64
        public let messageCoveredThroughSeq: Int64
        public let messageCoverageRequiresRecovery: Bool
        public let sequenceRecoveryAfterSeq: Int64?
        public let sequenceRecoveryThroughSeq: Int64?
        public let pendingLocalFinalizations: [PendingLocalMessageFinalization]

        public init(messages: [ChatMessage], latestMessage: ChatMessage?, incomingRealtimeMessages: [ChatMessage], latestKnownSeq: Int64, messageCoveredThroughSeq: Int64, messageCoverageRequiresRecovery: Bool, sequenceRecoveryAfterSeq: Int64?, sequenceRecoveryThroughSeq: Int64?, pendingLocalFinalizations: [PendingLocalMessageFinalization]) {
            self.messages = messages
            self.latestMessage = latestMessage
            self.incomingRealtimeMessages = incomingRealtimeMessages
            self.latestKnownSeq = latestKnownSeq
            self.messageCoveredThroughSeq = messageCoveredThroughSeq
            self.messageCoverageRequiresRecovery = messageCoverageRequiresRecovery
            self.sequenceRecoveryAfterSeq = sequenceRecoveryAfterSeq
            self.sequenceRecoveryThroughSeq = sequenceRecoveryThroughSeq
            self.pendingLocalFinalizations = pendingLocalFinalizations
        }
    }

    public struct MessageSequenceRecoveryTarget: Equatable, Sendable {
        public let afterSeq: Int64
        public let throughSeq: Int64

        public init(afterSeq: Int64, throughSeq: Int64) {
            self.afterSeq = max(0, afterSeq)
            self.throughSeq = max(self.afterSeq, throughSeq)
        }
    }

    public struct AppliedRemoteMessagesConversationResult: Sendable { // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        public let conversation: ConversationMessageSnapshot
        public let incomingRealtimeMessages: [ChatMessage]
        public let shouldPlayIncomingSound: Bool
        public let shouldAutoRead: Bool

        public init(conversation: ConversationMessageSnapshot, incomingRealtimeMessages: [ChatMessage], shouldPlayIncomingSound: Bool, shouldAutoRead: Bool) {
            self.conversation = conversation
            self.incomingRealtimeMessages = incomingRealtimeMessages
            self.shouldPlayIncomingSound = shouldPlayIncomingSound
            self.shouldAutoRead = shouldAutoRead
        }
    }

    public struct ConversationSettingChange: Sendable {
        public let previousValue: Bool
        public let conversation: ConversationMessageSnapshot

        public init(previousValue: Bool, conversation: ConversationMessageSnapshot) {
            self.previousValue = previousValue
            self.conversation = conversation
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

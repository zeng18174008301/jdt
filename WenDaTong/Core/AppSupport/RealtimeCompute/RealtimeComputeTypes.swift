// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import IM4Domain
import Foundation

// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
struct RealtimeDisplayClock: Equatable, Sendable {
    let calendar: Calendar
    let timeZone: TimeZone
    let day: Date
}

struct RealtimeMappingIdentity: Equatable, Sendable {
    struct GroupName: Equatable, Sendable { let id: String; let name: String }
    let currentUser: IMUser
    let currentIdentities: Set<String>
    let senderIdentities: Set<String>
    let outgoingSenderID: String
    let contacts: [IMUser]
    let directoryUsers: [IMUser]
    let remarks: [String: String]
    let groups: [GroupName]
    let resolvedAvatarURLs: [String: String]
    let readReceiptsEnabled: Bool
    let showsGroupMemberCount: Bool
    let clock: RealtimeDisplayClock
}

struct RemoteMessageDerivationOptions: Equatable, Sendable {
    let fromRealtime: Bool
    let windowRetention: ConversationStore.MessageWindowRetention
    let historyBoundary: ConversationStore.HistoryVisibilityBoundary?
    let sequenceCoverageAfterSeq: Int64?
    let olderHistoryBeforeSeq: Int64?
    let scheduleSequenceRecovery: Bool // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
    init(fromRealtime: Bool = true,
        windowRetention: ConversationStore.MessageWindowRetention = .preserveLoadedHistory,
        historyBoundary: ConversationStore.HistoryVisibilityBoundary? = nil,
        sequenceCoverageAfterSeq: Int64? = nil, olderHistoryBeforeSeq: Int64? = nil,
        scheduleSequenceRecovery: Bool = true) { // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
        self.fromRealtime = fromRealtime; self.windowRetention = windowRetention
        self.historyBoundary = historyBoundary; self.sequenceCoverageAfterSeq = sequenceCoverageAfterSeq
        self.olderHistoryBeforeSeq = olderHistoryBeforeSeq
        self.scheduleSequenceRecovery = scheduleSequenceRecovery // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
    }
}

struct RealtimeRawMessageGroup: Sendable {
    let messages: [RemoteMessage]
    let channelID: String
    let channelType: String
    let options: RemoteMessageDerivationOptions
    init(messages: [RemoteMessage], channelID: String, channelType: String,
        options: RemoteMessageDerivationOptions = RemoteMessageDerivationOptions()) {
        self.messages = messages; self.channelID = channelID; self.channelType = channelType; self.options = options
    }
}

struct RealtimeRemoteApplyContext: Equatable, Sendable {
    let channelID: String
    let channelType: String
    let targetID: String
    let kind: ConversationKind
    let boundary: ConversationStore.HistoryVisibilityBoundary?
    let participants: [IMUser]
    let effectiveReadSeq: Int64
    let title: String
    let memberCount: Int?
    let accentHex: UInt
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let active: Bool
    let canAutoRead: Bool
    let hiddenThroughSeq: Int64?
}

struct RealtimeComputeApplication: Sendable {
    let group: RealtimeRawMessageGroup
    let context: RealtimeRemoteApplyContext
    let expectedRawPrevious: ConversationMessageSnapshot?
    let expectedPrevious: ConversationMessageSnapshot?
    let visibleMessages: [RemoteMessage]
    let changesState: Bool
    let identity: RealtimeMappingIdentity
    let references: RealtimeMappingReferences
    let mapped: [ConversationStore.MappedRemoteMessage]
    let expectedGlobalRTC: [String: RTCCallRecordMessageDeduplicator.Authority]
    let relevantRTCKeys: Set<String>
    let mappingSideEffects: [RemoteMessage]
    let merge: ConversationStore.MergedRemoteMessagesResult
    let applied: ConversationStore.AppliedRemoteMessagesConversationResult?
#if DEBUG
    let mappedOnMainThread: Bool
    let mergedOnMainThread: Bool
#endif
}

struct RealtimeComputeInput: Sendable {
    let groups: [RealtimeRawMessageGroup]
    let contexts: [RealtimeRemoteApplyContext]
    let identity: RealtimeMappingIdentity
    let references: RealtimeMappingReferences
    let conversations: [ConversationMessageSnapshot]
    let trace: MessageDerivationTraceContext?
    let revision: UInt64
    let attempt: Int
    init(groups: [RealtimeRawMessageGroup], contexts: [RealtimeRemoteApplyContext],
        identity: RealtimeMappingIdentity, references: RealtimeMappingReferences,
        conversations: [ConversationMessageSnapshot], trace: MessageDerivationTraceContext? = nil,
        revision: UInt64 = 0, attempt: Int = 1) {
        self.groups = groups; self.contexts = contexts; self.identity = identity; self.references = references
        self.conversations = conversations; self.trace = trace; self.revision = revision; self.attempt = attempt
    }
}

struct RealtimeComputeOutput: Sendable {
    let applications: [RealtimeComputeApplication?]
    let relevantRTCKeys: Set<String>
    let samples: [MessageDerivationSample]
    init(applications: [RealtimeComputeApplication?], relevantRTCKeys: Set<String>, samples: [MessageDerivationSample] = []) {
        self.applications = applications; self.relevantRTCKeys = relevantRTCKeys; self.samples = samples
    }
}
// WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

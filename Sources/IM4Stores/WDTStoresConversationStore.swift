import Combine
import Foundation
import IM4Domain
import IM4Data

#if DEBUG
@MainActor
private enum ConversationStoreLagDiagnostics {
    static func elapsedMS(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    static func totalMessages(in conversations: [ConversationMessageSnapshot]) -> Int {
        conversations.reduce(0) { $0 + $1.messages.count }
    }

    static func logSlowCompare(
        startedAt: Date,
        current: [ConversationMessageSnapshot],
        next: [ConversationMessageSnapshot],
        changed: Bool, record: (String) -> Void
    ) {
        let elapsed = elapsedMS(since: startedAt)
        guard elapsed >= 12 else { return }
        let line = "[JHT Perf] conversation_store_compare_lag elapsed_ms=\(elapsed) current_count=\(current.count) next_count=\(next.count) current_messages=\(totalMessages(in: current)) next_messages=\(totalMessages(in: next)) changed=\(changed)"
        record(line)
    }
}
#endif

private struct ConversationStorePublishSignature: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: ConversationKind
    let lastMessage: String
    let time: String
    let unread: Int
    let isPinned: Bool
    let isMuted: Bool
    let memberCount: Int?
    let avatarURL: String
    let avatarVersion: String
    let avatarUpdatedAt: String
    let hasUnreadReaction: Bool
    let unreadReactionCount: Int
    let lastMsgSeq: Int64
    let messageCoveredThroughSeq: Int64
    let messageCoverageRequiresRecovery: Bool
    let lastReadSeq: Int64
    let firstUnreadSeq: Int64
    let firstUnreadMessageID: String
    let unreadAnchorSeq: Int64
    let unreadAnchorState: String
    let hasMention: Bool
    let mentionCount: Int
    let mentionSummaryText: String
    let mentionSummaryMessageID: String
    let mentionSummaryChannelSeq: Int64
    let sortTimestamp: TimeInterval
    let participantsCount: Int
    let messagesCount: Int
    let firstMessageID: String
    let firstMessageSeq: Int64
    let lastMessageID: String
    let lastMessageSeq: Int64

    init(_ conversation: ConversationMessageSnapshot) {
        let firstMessage = conversation.messages.first
        let lastMessage = conversation.messages.last
        id = conversation.id
        title = conversation.title
        subtitle = conversation.subtitle
        kind = conversation.kind
        self.lastMessage = conversation.lastMessage
        time = conversation.time
        unread = conversation.unread
        isPinned = conversation.isPinned
        isMuted = conversation.isMuted
        memberCount = conversation.memberCount
        avatarURL = conversation.avatarURL
        avatarVersion = conversation.avatarVersion
        avatarUpdatedAt = conversation.avatarUpdatedAt
        hasUnreadReaction = conversation.hasUnreadReaction
        unreadReactionCount = conversation.unreadReactionCount
        lastMsgSeq = conversation.lastMsgSeq
        messageCoveredThroughSeq = conversation.messageCoveredThroughSeq
        messageCoverageRequiresRecovery = conversation.messageCoverageRequiresRecovery
        lastReadSeq = conversation.lastReadSeq
        firstUnreadSeq = conversation.firstUnreadSeq
        firstUnreadMessageID = conversation.firstUnreadMessageID
        unreadAnchorSeq = conversation.unreadAnchorSeq
        unreadAnchorState = conversation.unreadAnchorState
        hasMention = conversation.hasMention
        mentionCount = conversation.mentionCount
        mentionSummaryText = conversation.mentionSummaryText
        mentionSummaryMessageID = conversation.mentionSummaryMessageID
        mentionSummaryChannelSeq = conversation.mentionSummaryChannelSeq
        sortTimestamp = conversation.sortTimestamp
        participantsCount = conversation.participants.count
        messagesCount = conversation.messages.count
        firstMessageID = firstMessage?.id ?? ""
        firstMessageSeq = firstMessage?.channelSeq ?? 0
        lastMessageID = lastMessage?.id ?? ""
        lastMessageSeq = lastMessage?.channelSeq ?? 0
    }
}

private func conversationStorePublishSignature(_ conversations: [ConversationMessageSnapshot]) -> [ConversationStorePublishSignature] {
    conversations.map(ConversationStorePublishSignature.init)
}

@MainActor
public final class ConversationStore: ObservableObject {
    // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
    // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_BEGIN
    public typealias MemorySnapshot = IM4Stores.ScopedMessageMemoryStore.MemorySnapshot
    public typealias MemoryCommit = IM4Stores.ScopedMessageMemoryStore.MemoryCommit
    public typealias MessageWindowChange = IM4Stores.ScopedMessageMemoryStore.MessageWindowChange
    public let messageMemoryStore: ScopedMessageMemoryStore
    private var memoryWillChangeSubscription: AnyCancellable?
    public var realtimeDerivationStamp: RealtimeDerivationStamp { messageMemoryStore.realtimeDerivationStamp }
    public var memorySnapshot: MemorySnapshot { messageMemoryStore.memorySnapshot }
    public var memoryUpdates: AnyPublisher<MemorySnapshot, Never> { messageMemoryStore.memoryUpdates }
    public var conversationUpdates: AnyPublisher<[Conversation], Never> { messageMemoryStore.conversationUpdates }
    public var memoryCommits: AnyPublisher<MemoryCommit, Never> { messageMemoryStore.memoryCommits }
    public var conversations: [Conversation] { messageMemoryStore.conversations }
    public var alertingUnreadTotal: Int { messageMemoryStore.alertingUnreadTotal }
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_BEGIN
    public func performRealtimeAtomicCommand(allowsSingleConversationUpdate: Bool = false, _ operation: () -> Void) {
        messageMemoryStore.performRealtimeAtomicCommand(allowsSingleConversationUpdate: allowsSingleConversationUpdate, operation)
    }
    // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112_END
    public func performMemoryCommand<Result>(presentationPageID: UUID? = nil,
        memoryDiagnostics: [MessageMemoryDiagnostic] = [], _ operation: () throws -> Result) rethrows -> Result {
        try messageMemoryStore.performMemoryCommand(presentationPageID: presentationPageID,
            realtimeSignposts: memoryDiagnostics, operation)
    }
    public func conversationMessageSnapshot(id: String) -> ConversationMessageSnapshot? {
        messageMemoryStore.conversationMessageSnapshot(id: id)
    }
    public func conversationMessageSnapshot(at index: Int) -> ConversationMessageSnapshot {
        messageMemoryStore.conversationMessageSnapshot(at: index)
    }
    public func conversationMessageSnapshots() -> [ConversationMessageSnapshot] {
        messageMemoryStore.conversationMessageSnapshots()
    }
    public func commitConversationSnapshot(_ snapshot: ConversationMessageSnapshot, at index: Int) {
        messageMemoryStore.commitConversationSnapshot(snapshot, at: index)
    }
    public func commitConversationChanges(_ changes: [Int: ConversationMessageSnapshot]) {
        messageMemoryStore.commitConversationChanges(changes)
    }
    public func commitConversationChanges(in values: [ConversationMessageSnapshot], at indices: Set<Int>, preparedAt: UInt64) {
        messageMemoryStore.commitConversationChanges(in: values, at: indices, preparedAt: preparedAt)
    }
    public func commitConversationSnapshots(_ input: [ConversationMessageSnapshot], unreadUpdate: ConversationUnreadUpdate = .rebuild) {
        messageMemoryStore.commitConversationSnapshots(input, unreadUpdate: unreadUpdate)
    }
    public func bindMessageScope(_ scope: LocalMessageScope?, preservesMessages: Bool) {
        messageMemoryStore.bindMessageScope(scope, preservesMessages: preservesMessages)
    }
    // WDT_IOS1_STORES_MESSAGE_MEMORY_20261110_END
    @Published public var historyLoadingIDs: Set<String> = []
    @Published public var historyMessages: [String: String] = [:]
    @Published public var directDisabledMessages: [String: String] = [:]
    @Published public var applyingFriendIDs: Set<String> = []

    // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110_BEGIN
    public struct ChatAvailabilitySnapshot: Equatable, Sendable {
        public let isHistoryLoading: Bool
        public let historyMessage: String?
        public let directDisabledMessage: String?
        public let isApplyingFriend: Bool
        public let friendRequestContext: DirectFriendRequestContext?

        public init(isHistoryLoading: Bool, historyMessage: String?, directDisabledMessage: String?, isApplyingFriend: Bool, friendRequestContext: DirectFriendRequestContext?) {
            self.isHistoryLoading = isHistoryLoading
            self.historyMessage = historyMessage
            self.directDisabledMessage = directDisabledMessage
            self.isApplyingFriend = isApplyingFriend
            self.friendRequestContext = friendRequestContext
        }
    }

    public func chatAvailability(for conversationID: String) -> ChatAvailabilitySnapshot {
        ChatAvailabilitySnapshot(
            isHistoryLoading: historyLoadingIDs.contains(conversationID),
            historyMessage: historyMessages[conversationID],
            directDisabledMessage: directDisabledMessages[conversationID],
            isApplyingFriend: applyingFriendIDs.contains(conversationID),
            friendRequestContext: directFriendRequestContexts[conversationID]
        )
    }

    public func chatAvailabilityUpdates(for conversationID: String) -> AnyPublisher<ChatAvailabilitySnapshot, Never> {
        Publishers.CombineLatest4(
            $historyLoadingIDs.map { $0.contains(conversationID) },
            $historyMessages.map { $0[conversationID] },
            $directDisabledMessages.map { $0[conversationID] },
            $applyingFriendIDs.map { $0.contains(conversationID) }
        )
        .combineLatest($directFriendRequestContexts.map { $0[conversationID] })
        .map { status, context in
            ChatAvailabilitySnapshot(
                isHistoryLoading: status.0,
                historyMessage: status.1,
                directDisabledMessage: status.2,
                isApplyingFriend: status.3,
                friendRequestContext: context
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
    // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110_END

    var locallyReadSeqs: [String: Int64] = [:]
    var scopedReadWatermarkSeqs: [String: Int64] = [:]
    var historyBackfillAfterSeqs: [String: Int64] = [:]
    var historyReachedStartKeys: Set<String> = []
    var historyLoadRequestTimes: [String: Date] = [:]
    var confirmedConversationBottomSeqByScope: [String: Int64] = [:]
    var activeRealtimeConversationAutoReadEnabled: [String: Bool] = [:]
    var appliedReactionExtraKeys: Set<String> = []
    var historySyncErrorToastTimesByConversationID: [String: Date] = [:]
    @Published public var directFriendRequestContexts: [String: DirectFriendRequestContext] = [:] // WDT_IOS1_REFACTOR_CHAT_AVAILABILITY_OBSERVATION_20261110
    var warmRefreshTasks: [String: Task<Void, Never>] = [:]
    var pendingReadAckSeqs: [String: Int64] = [:]
    var queuedReadAckSeqs: [String: Int64] = [:]
    var activeReadAckGenerations: [String: UInt64] = [:]
    var nextReadAckGeneration: UInt64 = 0
    var activeReceiptSyncGenerations: [String: UInt64] = [:]
    var nextReceiptSyncGeneration: UInt64 = 0
    var activeHistorySyncClaims: [String: HistorySyncClaim] = [:] // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
    let messageSyncEngine: any ConversationMessageSyncEngine
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_STATE - 修改开始：附件上传进度刷新节流状态，避免进度高频写消息数组导致滚动卡顿
    private struct AttachmentProgressPublishSnapshot {
        let progress: Double
        let updatedAt: Date
    }
    private var attachmentProgressPublishSnapshotsByKey: [String: AttachmentProgressPublishSnapshot] = [:]
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_STATE - 修改结束：附件上传进度刷新节流状态，避免进度高频写消息数组导致滚动卡顿

    private let normalizeRTCRecords: @MainActor ([ConversationMessageSnapshot]) -> [ConversationMessageSnapshot]
    private let recordLagDiagnostic: @MainActor (String) -> Void
    let rtcAuthority: @Sendable (ChatMessage) -> RTCCallRecordAuthority?
    let conversationListPreview: (ChatMessage) -> String

    public init(syncEngine: any ConversationMessageSyncEngine, scope: LocalMessageScope? = nil,
        rtcAuthorities: @escaping @Sendable ([ChatMessage]) -> [String: [RTCCallRecordAuthority]],
        rtcAuthority: @escaping @Sendable (ChatMessage) -> RTCCallRecordAuthority?,
        conversationListPreview: @escaping (ChatMessage) -> String,
        normalizeRTCRecords: @escaping @MainActor ([ConversationMessageSnapshot]) -> [ConversationMessageSnapshot],
        recordLagDiagnostic: @escaping @MainActor (String) -> Void = { _ in }) {
        self.messageSyncEngine = syncEngine
        self.normalizeRTCRecords = normalizeRTCRecords
        self.rtcAuthority = rtcAuthority
        self.conversationListPreview = conversationListPreview
        self.recordLagDiagnostic = recordLagDiagnostic
        self.messageMemoryStore = ScopedMessageMemoryStore(scope: scope, rtcAuthorities: rtcAuthorities)
        self.memoryWillChangeSubscription = messageMemoryStore.metadataWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_HELPER - 修改开始：附件上传进度发布阈值，保留开始/结束并合并细碎刷新
    private func attachmentProgressThrottleKey(conversationID: String, messageID: String) -> String {
        "\(conversationID)|\(messageID)"
    }

    private func shouldPublishAttachmentTransferProgress(
        current: Double?,
        next: Double,
        snapshot: AttachmentProgressPublishSnapshot?,
        now: Date,
        minimumDelta: Double = 0.025,
        minimumInterval: TimeInterval = 0.12
    ) -> Bool {
        guard let current else { return true }
        if next >= 0.995 { return true }
        if abs(next - current) >= minimumDelta { return true }
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.updatedAt) >= minimumInterval
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_HELPER - 修改结束：附件上传进度发布阈值，保留开始/结束并合并细碎刷新

    @discardableResult
    public func publishConversationsIfChanged(_ next: [ConversationMessageSnapshot], unreadUpdate: ConversationUnreadUpdate = .rebuild) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_PUBLISH_COMPARE - 修改开始：记录随会话消息增长可能变慢的全量相等比较
            let currentSnapshot = conversationMessageSnapshots()
            // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_LAG_FIX_PUBLISH_FAST_PATH - 修改开始：签名不同表示一定有可发布变化，跳过昂贵深比较
            let currentSignature = conversationStorePublishSignature(currentSnapshot)
            let nextSignature = conversationStorePublishSignature(next)
            guard currentSignature == nextSignature else {
                commitConversationSnapshots(next, unreadUpdate: unreadUpdate)
                return true
            }
            // JHT_MOD_END CONVERSATION_LIST_SCROLL_LAG_FIX_PUBLISH_FAST_PATH - 修改结束
            #if DEBUG
            let compareStartedAt = Date()
            let changed = currentSnapshot != next
            ConversationStoreLagDiagnostics.logSlowCompare(
                startedAt: compareStartedAt,
                current: currentSnapshot,
                next: next,
                changed: changed, record: recordLagDiagnostic
            )
            guard changed else { return false }
            #else
            guard currentSnapshot != next else { return false }
            #endif
            // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_PUBLISH_COMPARE - 修改结束
            commitConversationSnapshots(next, unreadUpdate: unreadUpdate)
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：给外部快照收敛路径提供“变了才发布”的安全入口
    @discardableResult
    public func replaceConversationsIfChanged(_ next: [ConversationMessageSnapshot], reason: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            #if DEBUG
            let startedAt = Date()
            let previousCount = conversations.count
            #endif
            let published = publishConversationsIfChanged(next)
            #if DEBUG
            let elapsed = ConversationStoreLagDiagnostics.elapsedMS(since: startedAt)
            if elapsed >= 8 || !published {
                let line = "[JHT Perf] conversation_store_publish_gate reason=\(reason) published=\(published) elapsed_ms=\(elapsed) previous_count=\(previousCount) next_count=\(next.count)"
                recordLagDiagnostic(line)
            }
            #endif
            return published
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }
    // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束

    public func deduplicatedConversationsByID(_ source: [ConversationMessageSnapshot]) -> [ConversationMessageSnapshot] {
        var orderedKeys: [String] = []
        var conversationsByKey: [String: ConversationMessageSnapshot] = [:]
        for conversation in source {
            let key = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = conversationsByKey[key] {
                if conversationListPrecedes(conversation, existing) {
                    conversationsByKey[key] = conversation
                }
            } else {
                orderedKeys.append(key)
                conversationsByKey[key] = conversation
            }
        }
        guard orderedKeys.count != source.count else { return source }
        return orderedKeys.compactMap { conversationsByKey[$0] }
    }

    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
    public func conversationsEnforcingGlobalRTCCallRecordExactOnce(_ source: [ConversationMessageSnapshot]) -> [ConversationMessageSnapshot] {
        normalizeRTCRecords(source)
    }
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

    public func scrubGroupMemberTotals() {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            publishConversationsIfChanged(conversationMessageSnapshots().map { $0.scrubbingGroupMemberTotals() }, unreadUpdate: .preserve)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    public func conversation(id: String) -> Conversation? { messageMemoryStore.conversation(id: id) }

    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_BEGIN
    public func conversationForPresentation(id: String) -> Conversation? {
        conversation(id: id) ?? Self.systemPresentationFallback(id: id, in: conversations)
    }

    public func conversationMessagePresentation(id: String) -> ConversationMessageSnapshot? {
        conversationForPresentation(id: id).map {
            ConversationMessageSnapshot(conversation: $0, messages: messageMemoryStore.commandMessages(for: $0.id))
        }
    }

    public func conversationPresentationUpdates(id: String) -> AnyPublisher<Conversation?, Never> {
        conversationUpdates // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110
            .map { values in
                values.first { $0.id == id } ?? Self.systemPresentationFallback(id: id, in: values)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
    public lazy var alertingUnreadUpdates: AnyPublisher<Int, Never> = memoryUpdates
        .map(\.alertingUnreadTotal).removeDuplicates().eraseToAnyPublisher()
    // WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END

    private static func systemPresentationFallback(id: String, in conversations: [Conversation]) -> Conversation? {
        guard ConversationChannelIdentityMapper.conversationKind(from: "", channelID: id) == .system else { return nil }
        return conversations.first { $0.kind == .system }
    }
    // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_END

    @discardableResult
    public func hydrateCachedConversations(_ cachedConversations: [ConversationMessageSnapshot]) -> Int {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let exactOnceConversations = conversationsEnforcingGlobalRTCCallRecordExactOnce(cachedConversations)
            publishConversationsIfChanged(deduplicatedConversationsByID(exactOnceConversations))
            return conversations.count
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    public func updateAttachmentProgress(_ progress: Double?, messageID: String, conversationID: String) -> ChatMessage? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
            // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_APPLY - 修改开始：上传进度小幅高频变化不反复写消息数组，降低图片/附件消息滑动卡顿
            let throttleKey = attachmentProgressThrottleKey(
                conversationID: normalizedConversationID,
                messageID: normalizedMessageID
            )
            let currentProgress = conversationMessageSnapshot(at: cIndex).messages[mIndex].attachmentTransferProgress
            if let progress {
                let boundedProgress = max(0, min(progress, 1))
                let now = Date()
                guard shouldPublishAttachmentTransferProgress(
                    current: currentProgress,
                    next: boundedProgress,
                    snapshot: attachmentProgressPublishSnapshotsByKey[throttleKey],
                    now: now
                ) else { return nil }
                attachmentProgressPublishSnapshotsByKey[throttleKey] = AttachmentProgressPublishSnapshot(
                    progress: boundedProgress,
                    updatedAt: now
                )
                mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.attachmentTransferProgress = boundedProgress } // WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110
            } else {
                attachmentProgressPublishSnapshotsByKey[throttleKey] = nil
                guard currentProgress != nil else { return conversationMessageSnapshot(at: cIndex).messages[mIndex] }
                mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.attachmentTransferProgress = nil } // WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110
            }
            // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_APPLY - 修改结束：上传进度小幅高频变化不反复写消息数组，降低图片/附件消息滑动卡顿
            return conversationMessageSnapshot(at: cIndex).messages[mIndex]
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    public func reset() {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            activeHistorySyncClaims.removeAll() // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            bindMessageScope(messageMemoryStore.commandScope, preservesMessages: false)
            historyLoadingIDs = []
            historyMessages = [:]
            directDisabledMessages = [:]
            applyingFriendIDs = []
            locallyReadSeqs.removeAll()
            scopedReadWatermarkSeqs.removeAll()
            pendingReadAckSeqs.removeAll()
            queuedReadAckSeqs.removeAll()
            activeReadAckGenerations.removeAll()
            activeReceiptSyncGenerations.removeAll()
            historyBackfillAfterSeqs.removeAll()
            historyReachedStartKeys.removeAll()
            historyLoadRequestTimes.removeAll()
            confirmedConversationBottomSeqByScope.removeAll()
            activeRealtimeConversationAutoReadEnabled.removeAll()
            appliedReactionExtraKeys.removeAll()
            historySyncErrorToastTimesByConversationID.removeAll()
            directFriendRequestContexts.removeAll()
            messageSyncEngine.reset()
            cancelAllWarmRefreshTasks()
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }
}

public struct ConversationSelectionEpochFence: Sendable {
    public init() {}
    public typealias Token = ConversationStore.ConversationSelectionRequestToken

    public private(set) var epoch: UInt64 = 0
    public private(set) var activeScope = ""
    public private(set) var activeConversationID = ""

    public mutating func select(scope: String, conversationID: String) -> Token {
        epoch &+= 1
        activeScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        activeConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Token(scope: activeScope, conversationID: activeConversationID, epoch: epoch)
    }

    public mutating func leave(scope: String, conversationID: String) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeScope == normalizedScope,
              activeConversationID == normalizedConversationID else { return }
        invalidate()
    }

    public mutating func invalidate() {
        epoch &+= 1
        activeScope = ""
        activeConversationID = ""
    }

    public func token(scope: String, conversationID: String) -> Token? {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty,
              !normalizedConversationID.isEmpty,
              activeScope == normalizedScope,
              activeConversationID == normalizedConversationID else { return nil }
        return Token(scope: activeScope, conversationID: activeConversationID, epoch: epoch)
    }

    public func accepts(_ token: Token) -> Bool {
        token.epoch == epoch
            && token.scope == activeScope
            && token.conversationID == activeConversationID
    }
}

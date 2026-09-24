import Foundation

func textRemovingGroupMemberTotals(_ raw: String) -> String {
    raw.replacingOccurrences(
        of: #"(?:(?:群(?:成员)?(?:总数|人数)?|共|当前|现有)\s*[：:]?\s*)?\d+\s*(?:名|位|个)?\s*(?:群成员|成员|人)"#,
        with: "群成员",
        options: .regularExpression
    ).replacingOccurrences(
        of: #"(?i)(?:(?:total|current)\s*)?\d+\s*(?:group\s*)?members?"#,
        with: "group members",
        options: .regularExpression
    )
}

private extension MessageReplyContext {
    func scrubbingGroupMemberTotals() -> MessageReplyContext {
        var scrubbed = self
        scrubbed.summary = textRemovingGroupMemberTotals(scrubbed.summary)
        return scrubbed
    }
}

extension Conversation {
    func scrubbingGroupMemberTotals() -> Conversation {
        guard kind == .group else { return self }
        var scrubbed = self
        scrubbed.memberCount = nil
        scrubbed.subtitle = textRemovingGroupMemberTotals(scrubbed.subtitle)
        scrubbed.lastMessage = textRemovingGroupMemberTotals(scrubbed.lastMessage)
        scrubbed.mentionSummaryText = textRemovingGroupMemberTotals(scrubbed.mentionSummaryText)
        scrubbed.messages = scrubbed.messages.map { message in
            var scrubbedMessage = message
            scrubbedMessage.readCount = nil
            scrubbedMessage.unreadCount = nil
            scrubbedMessage.quote = scrubbedMessage.quote.map(textRemovingGroupMemberTotals)
            scrubbedMessage.replyContext = scrubbedMessage.replyContext?.scrubbingGroupMemberTotals()
            if scrubbedMessage.kind == .system {
                scrubbedMessage.text = textRemovingGroupMemberTotals(scrubbedMessage.text)
            }
            return scrubbedMessage
        }
        return scrubbed
    }
}

// JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_STORE - 修改开始：检测会话列表数据发布前的重比较耗时
#if DEBUG
// JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_FILE_TRACE - 修改开始：会话列表卡顿自动落盘，便于长时间使用后回收证据
private actor ConversationListLagTraceWriter {
    static let shared = ConversationListLagTraceWriter()

    private let fileURL: URL
    private let maxBytes = 512 * 1024
    private var didAnnounceFile = false

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        fileURL = directory.appendingPathComponent("conversation-list-lag.log", isDirectory: false)
    }

    func append(_ line: String) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded(fileManager: fileManager)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let payload = Data("\(timestamp) \(line)\n".utf8)
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(payload)
            handle.closeFile()
            if !didAnnounceFile {
                didAnnounceFile = true
                print("[JHT Perf] conversation_list_lag_log_file path=\(fileURL.path)")
            }
        } catch {
            print("[JHT Perf] conversation_list_lag_log_file_failed error=\(error.localizedDescription)")
        }
    }

    private func rotateIfNeeded(fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        try? fileManager.removeItem(at: fileURL)
    }
}

enum ConversationListLagTraceRecorder {
    static func record(_ line: String) {
        Task.detached(priority: .utility) {
            await ConversationListLagTraceWriter.shared.append(line)
        }
    }
}
// JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_FILE_TRACE - 修改结束

private enum ConversationStoreLagDiagnostics {
    static func elapsedMS(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    static func totalMessages(in conversations: [Conversation]) -> Int {
        conversations.reduce(0) { $0 + $1.messages.count }
    }

    static func logSlowCompare(
        startedAt: Date,
        current: [Conversation],
        next: [Conversation],
        changed: Bool
    ) {
        let elapsed = elapsedMS(since: startedAt)
        guard elapsed >= 12 else { return }
        let line = "[JHT Perf] conversation_store_compare_lag elapsed_ms=\(elapsed) current_count=\(current.count) next_count=\(next.count) current_messages=\(totalMessages(in: current)) next_messages=\(totalMessages(in: next)) changed=\(changed)"
        print(line)
        ConversationListLagTraceRecorder.record(line)
    }
}
#endif
// JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_STORE - 修改结束

// JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_LAG_FIX_STORE_SIGNATURE - 修改开始：发布前使用轻量签名快路径，避免每次深比较完整 messages
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

    init(_ conversation: Conversation) {
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

private func conversationStorePublishSignature(_ conversations: [Conversation]) -> [ConversationStorePublishSignature] {
    conversations.map(ConversationStorePublishSignature.init)
}
// JHT_MOD_END CONVERSATION_LIST_SCROLL_LAG_FIX_STORE_SIGNATURE - 修改结束

// A synchronous projection uses one identity snapshot; never retain it across awaits.
// JHT_MOD_BEGIN APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改开始：会话身份 lookup 是值快照，可安全用于 AppState 外部纯映射
struct ConversationUserLookup: Sendable {
// JHT_MOD_END APPSTATE_CHANNEL_IDENTITY_MAPPER_SPLIT_20260913 - 修改结束
    private var users: [String: IMUser] = [:]

    init(currentUser: IMUser, currentIdentifiers: Set<String>, contacts: [IMUser], groupMembers: [IMUser]) {
        for identifier in currentIdentifiers where !identifier.isEmpty {
            users[identifier] = currentUser
        }
        for user in contacts + groupMembers {
            for value in [user.id, user.userID, user.username] {
                let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !identifier.isEmpty, users[identifier] == nil {
                    users[identifier] = user
                }
            }
        }
    }

    func user(for identifier: String) -> IMUser? {
        users[identifier.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published private var historyLoadingIDs: Set<String> = []
    @Published private var historyMessages: [String: String] = [:]
    @Published private var directDisabledMessages: [String: String] = [:]
    @Published private var applyingFriendIDs: Set<String> = []

    private var locallyReadSeqs: [String: Int64] = [:]
    private var scopedReadWatermarkSeqs: [String: Int64] = [:]
    private var historyBackfillAfterSeqs: [String: Int64] = [:]
    private var historyReachedStartKeys: Set<String> = []
    private var historyLoadRequestTimes: [String: Date] = [:]
    private var confirmedConversationBottomSeqByScope: [String: Int64] = [:]
    private var activeRealtimeConversationAutoReadEnabled: [String: Bool] = [:]
    private var appliedReactionExtraKeys: Set<String> = []
    private var historySyncErrorToastTimesByConversationID: [String: Date] = [:]
    private var directFriendRequestContexts: [String: DirectFriendRequestContext] = [:]
    private var warmRefreshTasks: [String: Task<Void, Never>] = [:]
    private var pendingReadAckSeqs: [String: Int64] = [:]
    private var queuedReadAckSeqs: [String: Int64] = [:]
    private var activeReadAckGenerations: [String: UInt64] = [:]
    private var nextReadAckGeneration: UInt64 = 0
    private var activeReceiptSyncGenerations: [String: UInt64] = [:]
    private var nextReceiptSyncGeneration: UInt64 = 0
    private let messageSyncEngine: any SyncEngine
    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_STATE - 修改开始：附件上传进度刷新节流状态，避免进度高频写消息数组导致滚动卡顿
    private struct AttachmentProgressPublishSnapshot {
        let progress: Double
        let updatedAt: Date
    }
    private var attachmentProgressPublishSnapshotsByKey: [String: AttachmentProgressPublishSnapshot] = [:]
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_STATE - 修改结束：附件上传进度刷新节流状态，避免进度高频写消息数组导致滚动卡顿

    init(messageSyncEngine: any SyncEngine = DefaultSyncEngine()) {
        self.messageSyncEngine = messageSyncEngine
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
    private func publishConversationsIfChanged(_ next: [Conversation]) -> Bool {
        // JHT_MOD_BEGIN CONVERSATION_LIST_LAG_DIAG_PUBLISH_COMPARE - 修改开始：记录随会话消息增长可能变慢的全量相等比较
        let currentSnapshot = conversations
        // JHT_MOD_BEGIN CONVERSATION_LIST_SCROLL_LAG_FIX_PUBLISH_FAST_PATH - 修改开始：签名不同表示一定有可发布变化，跳过昂贵深比较
        let currentSignature = conversationStorePublishSignature(currentSnapshot)
        let nextSignature = conversationStorePublishSignature(next)
        guard currentSignature == nextSignature else {
            conversations = next
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
            changed: changed
        )
        guard changed else { return false }
        #else
        guard currentSnapshot != next else { return false }
        #endif
        // JHT_MOD_END CONVERSATION_LIST_LAG_DIAG_PUBLISH_COMPARE - 修改结束
        conversations = next
        return true
    }

    // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：给外部快照收敛路径提供“变了才发布”的安全入口
    @discardableResult
    func replaceConversationsIfChanged(_ next: [Conversation], reason: String) -> Bool {
        #if DEBUG
        let startedAt = Date()
        let previousCount = conversations.count
        #endif
        let published = publishConversationsIfChanged(next)
        #if DEBUG
        let elapsed = ConversationStoreLagDiagnostics.elapsedMS(since: startedAt)
        if elapsed >= 8 || !published {
            let line = "[JHT Perf] conversation_store_publish_gate reason=\(reason) published=\(published) elapsed_ms=\(elapsed) previous_count=\(previousCount) next_count=\(next.count)"
            print(line)
            ConversationListLagTraceRecorder.record(line)
        }
        #endif
        return published
    }
    // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束

    private func deduplicatedConversationsByID(_ source: [Conversation]) -> [Conversation] {
        var orderedKeys: [String] = []
        var conversationsByKey: [String: Conversation] = [:]
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

    private func conversationsEnforcingGlobalRTCCallRecordExactOnce(
        _ source: [Conversation]
    ) -> [Conversation] {
        var globalRTCAuthorities: [String: (conversationID: String, authority: RTCCallRecordMessageDeduplicator.Authority)] = [:]
        return source.map { conversation in
            var normalized = conversation
            let originalLatestMessageID = latestConfirmedMessage(in: conversation.messages)?.id
            var removedOriginalLatest = false
            var messages: [ChatMessage] = []
            for message in conversation.messages {
                guard let authority = RTCCallRecordMessageDeduplicator.authority(for: message) else {
                    messages.append(message)
                    continue
                }
                if let existing = globalRTCAuthorities[authority.callID] {
                    if existing.conversationID != conversation.id || existing.authority != authority,
                       authority.channelSeq > 0 {
                        normalized.messageCoveredThroughSeq = min(
                            normalized.messageCoveredThroughSeq,
                            max(0, authority.channelSeq - 1)
                        )
                        normalized.messageCoverageRequiresRecovery = true
                    }
                    removedOriginalLatest = removedOriginalLatest || message.id == originalLatestMessageID
                    continue
                }
                globalRTCAuthorities[authority.callID] = (conversation.id, authority)
                messages.append(message)
            }
            normalized.messages = messages
            if removedOriginalLatest {
                if let latest = latestConfirmedMessage(in: messages) {
                    normalized.lastMessage = messageListPreview(latest)
                    normalized.time = latest.time
                } else {
                    normalized.lastMessage = ""
                    normalized.time = ""
                }
            }
            return normalized
        }
    }

    func scrubGroupMemberTotals() {
        publishConversationsIfChanged(conversations.map { $0.scrubbingGroupMemberTotals() })
    }

    struct MessageSyncWindow: Equatable {
        let afterSeq: Int64
        let limit: Int
    }

    enum MessageSyncPlan: Equatable {
        case sidecarsOnly
        case remoteHistory(historyKey: String, windows: [MessageSyncWindow])
    }

    enum MessageWindowRetention: Equatable {
        case preserveLoadedHistory
        case latestTail(limit: Int)
    }

    struct MessageSidecarSyncKeyContext: Equatable {
        let tenantID: String
        let imUID: String
        let channelID: String
        let channelType: String
        let normalizedChannelID: String
        let suffix: String

        init(
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

        var syncKey: String {
            [tenantID, imUID, channelType, normalizedChannelID, suffix]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    struct ReadReceiptSidecarSyncTarget: Equatable {
        let channelID: String
        let channelType: String

        init(channelID: String, channelType: String) {
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct ConversationReadStateKeyContext: Equatable {
        let channelID: String
        let channelType: String
        let normalizedChannelID: String

        init(channelID: String, channelType: String, normalizedChannelID: String) {
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.normalizedChannelID = normalizedChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var syncKey: String {
            "\(channelType)|\(normalizedChannelID)"
        }
    }

    struct ReadWatermarkScope: Equatable, Hashable {
        let tenantID: String
        let imUID: String
        let appID: String
        let channelID: String
        let channelType: String

        init?(
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

        var storageKey: String {
            [tenantID, imUID, appID, channelType, channelID].joined(separator: "\u{0}")
        }

        var readStateKey: String {
            "\(channelType)|\(channelID)"
        }
    }

    struct ReadWatermark: Equatable {
        let eventID: String
        let scope: ReadWatermarkScope
        let lastReadSeq: Int64
        let occurredAt: String

        init?(
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

    struct ConversationHistoryKeyContext: Equatable {
        let tenantID: String
        let imUID: String
        let conversationID: String

        init(tenantID: String, imUID: String, conversationID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var historyKey: String {
            [tenantID, imUID, conversationID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    struct PinnedMessagesRefreshKeyContext: Equatable {
        let tenantID: String
        let imUID: String
        let conversationID: String
        let channelID: String

        init(tenantID: String, imUID: String, conversationID: String, channelID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var refreshKey: String {
            [tenantID, imUID, conversationID, channelID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }
    }

    struct OlderHistoryAvailabilityTarget: Equatable {
        let historyKey: String
        let conversationID: String
        let oldestSeq: Int64

        init(historyKey: String, conversationID: String, oldestSeq: Int64) {
            self.historyKey = historyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.oldestSeq = max(0, oldestSeq)
        }
    }

    enum OlderHistoryAvailabilityPlan: Equatable {
        case available(OlderHistoryAvailabilityTarget)
        case reachedStart(historyKey: String, conversationID: String)
        case unavailable(historyKey: String, conversationID: String)
    }

    struct NewerHistoryAvailabilityTarget: Equatable {
        let historyKey: String
        let conversationID: String
        let afterSeq: Int64
        let latestKnownSeq: Int64
        let limit: Int

        init(historyKey: String, conversationID: String, afterSeq: Int64, latestKnownSeq: Int64, limit: Int) {
            self.historyKey = historyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.afterSeq = max(0, afterSeq)
            self.latestKnownSeq = max(0, latestKnownSeq)
            self.limit = max(1, limit)
        }
    }

    struct ConversationPollingPlan: Equatable {
        let conversationID: String
        let historyKey: String
        let shouldPollActiveConversation: Bool
        let isMessageSyncInFlight: Bool

        init(
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

        var shouldPoll: Bool {
            shouldPollActiveConversation && !isMessageSyncInFlight
        }
    }

    struct ActiveConversationScopedStateKeyContext: Equatable {
        let tenantID: String
        let imUID: String
        let conversationID: String

        init(tenantID: String, imUID: String, conversationID: String) {
            self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imUID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var scope: String {
            [tenantID, imUID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }

        var stateKey: String {
            "\(scope)|\(conversationID)"
        }
    }

    struct ReadAckCommand: Equatable {
        let syncKey: String
        let targetSeq: Int64?

        init(syncKey: String, targetSeq: Int64? = nil) {
            self.syncKey = syncKey
            if let targetSeq, targetSeq > 0 {
                self.targetSeq = targetSeq
            } else {
                self.targetSeq = nil
            }
        }
    }

    struct ReadAckSyncClaim: Equatable {
        let command: ReadAckCommand
        fileprivate let generation: UInt64
    }

    enum ReadAckSyncPlan: Equatable {
        case clearLocally(ReadAckCommand)
        case remoteAck(ReadAckCommand)
        case queue(ReadAckCommand)
        case skip(ReadAckCommand, reason: String)
    }

    struct MessageReceiptsSyncCommand: Equatable {
        let syncKey: String
        let channelID: String
        let channelType: String
        let afterSeq: Int64
        let receiptType: String
        let limit: Int

        init(
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

    struct MessageReceiptsSyncClaim: Equatable {
        let syncKey: String
        let generation: UInt64
    }

    struct PendingDirectReadWindow {
        struct Identity: Equatable {
            let sequence: Int64
            let senderID: String
        }
        let conversationID: String
        let messages: [String: Identity]
        let sequences: [Int64]

        func afterSequence(through watermark: Int64 = 0) -> Int64? {
            sequences.first(where: { $0 > watermark }).map { $0 - 1 }
        }
    }

    func pendingDirectReadWindow(
        channelID: String,
        senderIdentities: Set<String>,
        channelIDForConversation: (Conversation) -> String
    ) -> PendingDirectReadWindow? {
        guard let conversation = conversations.first(where: {
            $0.id == channelID || channelIDForConversation($0) == channelID
        }), conversation.kind == .direct else { return nil }
        var identities: [String: PendingDirectReadWindow.Identity] = [:]
        for message in conversation.messages where message.isOutgoing && message.status == .sent {
            let senderID = message.senderId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard message.channelSeq > 0, !message.id.isEmpty, !message.id.hasPrefix("local_"),
                  !message.isDeletedLocally, !message.isPinnedContextOnly,
                  (message.readCount ?? 0) == 0, message.readBy.isEmpty,
                  senderIdentities.contains(senderID) else { continue }
            identities[message.id] = .init(sequence: message.channelSeq, senderID: senderID)
        }
        guard !identities.isEmpty else { return nil }
        return PendingDirectReadWindow(
            conversationID: conversation.id, messages: identities,
            sequences: Set(identities.values.map(\.sequence)).sorted()
        )
    }

    @discardableResult
    func applyDirectReadWatermark(
        _ watermark: Int64,
        window: PendingDirectReadWindow,
        readReceiptsEnabled: Bool
    ) -> Bool {
        guard readReceiptsEnabled, watermark > 0,
              let index = conversations.firstIndex(where: { $0.id == window.conversationID && $0.kind == .direct }) else { return false }
        var conversation = conversations[index]
        var changed = false
        // Only identities captured before the authenticated request may inherit its scalar.
        for messageIndex in conversation.messages.indices {
            var message = conversation.messages[messageIndex]
            guard let identity = window.messages[message.id],
                  message.isOutgoing, message.status == .sent,
                  !message.isDeletedLocally, !message.isPinnedContextOnly,
                  message.channelSeq == identity.sequence, identity.sequence <= watermark,
                  message.senderId.trimmingCharacters(in: .whitespacesAndNewlines) == identity.senderID else { continue }
            message.status = .read
            message.readStateKnown = true
            message.deliveryStateKnown = true
            // A scalar proves read state, never reader identity, device or count.
            if message.readBy.isEmpty && (message.readCount ?? 0) == 0 {
                message.readCount = nil
                message.unreadCount = nil
                message.unreadBy = []
                message.canViewReadDetails = false
            }
            conversation.messages[messageIndex] = message
            changed = true
        }
        guard changed else { return false }
        conversations[index] = conversation
        return true
    }

    enum MessageReceiptsSyncPlan: Equatable {
        case sync(MessageReceiptsSyncCommand)
        case skip(MessageReceiptsSyncCommand, reason: String)
    }

    struct MessageExtrasSyncCommand: Equatable {
        let syncKey: String
        let channelID: String
        let channelType: String
        let afterVersion: Int64
        let limit: Int

        init(
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

    enum MessageExtrasSyncPlan: Equatable {
        case sync(MessageExtrasSyncCommand)
        case skip(MessageExtrasSyncCommand, reason: String)
    }

    struct HistoryPrefetchCandidate {
        let remote: RemoteConversation
        let channelID: String
        let local: Conversation?
        let isActive: Bool
        let latestSeq: Int64
        let sortTimestamp: TimeInterval
        let logID: String
    }

    struct HistoryPrefetchTarget {
        let remote: RemoteConversation
        let channelID: String
        let reason: String
        let latestSeq: Int64
        let sortTimestamp: TimeInterval
        let logID: String

        var summaryFragment: String {
            "\(logID)#seq\(latestSeq)#ts\(Int(sortTimestamp))#\(reason)"
        }
    }

    struct HistoryPrefetchFetchCommand {
        let remote: RemoteConversation
        let channelID: String
        let apiChannelID: String
        let channelType: String
        let afterSeq: Int64
        let limit: Int
        let reason: String
        let summaryFragment: String
    }

    struct HistoryPrefetchExecutionPlan {
        let commands: [HistoryPrefetchFetchCommand]
        let maxConcurrent: Int

        var targetSummary: String {
            commands.map(\.summaryFragment)
                .joined(separator: ",")
        }

        var batches: [[HistoryPrefetchFetchCommand]] {
            guard !commands.isEmpty else { return [] }
            return stride(from: 0, to: commands.count, by: maxConcurrent).map { startIndex in
                Array(commands[startIndex..<min(startIndex + maxConcurrent, commands.count)])
            }
        }
    }

    struct HistoryPrefetchReadReceiptBackfillTarget: Equatable {
        let channelID: String
        let channelType: String
    }

    struct MappedRemoteMessage {
        let remote: RemoteMessage
        let message: ChatMessage
        let clientMessageIDs: Set<String>
        let isRemoteFromCurrentUser: Bool
        let matchedLocalID: String?
    }

    struct PendingLocalMessageFinalization {
        let localID: String
        let remoteMessage: ChatMessage
    }

    struct ConfirmedLocalMessageReplacement {
        let previousMessage: ChatMessage
        let confirmedMessage: ChatMessage
    }

    struct PinnedMessageSnapshotEntry {
        let messageID: String
        let status: String
        let message: ChatMessage
    }

    struct HistoryVisibilityBoundary: Equatable, Sendable {
        let fromSeq: Int64
        let limited: Bool
        let confirmed: Bool

        init(fromSeq: Int64, limited: Bool, confirmed: Bool = true) {
            self.fromSeq = max(1, fromSeq)
            self.limited = limited
            self.confirmed = confirmed
        }

        var isRestrictive: Bool {
            limited || fromSeq > 1
        }
    }

    struct ConversationSelectionRequestToken: Equatable, Sendable {
        let scope: String
        let conversationID: String
        let epoch: UInt64
    }

    struct RemoteConversationMergeEntry {
        let channelID: String
        let remote: RemoteConversation
        let conversation: Conversation
    }

    struct RemoteConversationSoundCandidate {
        let previous: Conversation
        let remote: RemoteConversation
        let mapped: Conversation
    }

    struct MergedRemoteConversationsResult {
        let conversations: [Conversation]
        let soundCandidates: [RemoteConversationSoundCandidate]
    }

    struct MergedRemoteMessagesResult {
        let messages: [ChatMessage]
        let latestMessage: ChatMessage?
        let incomingRealtimeMessages: [ChatMessage]
        let latestKnownSeq: Int64
        let messageCoveredThroughSeq: Int64
        let messageCoverageRequiresRecovery: Bool
        let sequenceRecoveryAfterSeq: Int64?
        let sequenceRecoveryThroughSeq: Int64?
        let pendingLocalFinalizations: [PendingLocalMessageFinalization]
    }

    struct MessageSequenceRecoveryTarget: Equatable {
        let afterSeq: Int64
        let throughSeq: Int64

        init(afterSeq: Int64, throughSeq: Int64) {
            self.afterSeq = max(0, afterSeq)
            self.throughSeq = max(self.afterSeq, throughSeq)
        }
    }

    struct AppliedRemoteMessagesConversationResult {
        let conversation: Conversation
        let incomingRealtimeMessages: [ChatMessage]
        let shouldPlayIncomingSound: Bool
        let shouldAutoRead: Bool
    }

    struct ConversationSettingChange {
        let previousValue: Bool
        let conversation: Conversation
    }

    func conversation(id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func hydrateCachedConversations(_ cachedConversations: [Conversation]) -> Int {
        let exactOnceConversations = conversationsEnforcingGlobalRTCCallRecordExactOnce(cachedConversations)
        publishConversationsIfChanged(deduplicatedConversationsByID(exactOnceConversations))
        return conversations.count
    }

    func conversationAwaitingHistoryBoundaryConfirmation(_ conversation: Conversation) -> Conversation {
        guard conversation.kind == .group else { return conversation }
        var updated = conversation
        updated.messages = []
        updated.lastMessage = ""
        updated.time = ""
        updated.unread = 0
        updated.hasUnreadReaction = false
        updated.unreadReactionCount = 0
        updated.firstUnreadSeq = 0
        updated.firstUnreadMessageID = ""
        updated.messageCoveredThroughSeq = 0
        updated.unreadAnchorSeq = 0
        updated.unreadAnchorState = "none"
        updated.hasMention = false
        updated.mentionCount = 0
        updated.mentionSummaryText = ""
        updated.mentionSummaryMessageID = ""
        updated.mentionSummaryChannelSeq = 0
        updated.sortTimestamp = 0
        updated.historyBoundaryConfirmed = false
        return updated
    }

    func conversationPreparedForLocalHistoryProjection(_ conversation: Conversation) -> Conversation {
        CachedConversationHistoryProjection.preparedForLocalHistoryProjection(conversation)
    }

    func historyBoundary(for conversation: Conversation?) -> HistoryVisibilityBoundary? {
        guard let conversation, conversation.kind == .group else { return nil }
        guard conversation.historyBoundaryConfirmed || conversation.historyLimited || conversation.historyVisibleFromSeq > 1 else { return nil }
        return HistoryVisibilityBoundary(
            fromSeq: conversation.historyVisibleFromSeq,
            limited: conversation.historyLimited,
            confirmed: conversation.historyBoundaryConfirmed
        )
    }

    func historyVisibleMessages(
        _ messages: [ChatMessage],
        boundary: HistoryVisibilityBoundary?,
        keepPendingLocalMessages: Bool = true
    ) -> [ChatMessage] {
        guard let boundary, boundary.isRestrictive else { return messages }
        return messages.filter { message in
            if message.channelSeq >= boundary.fromSeq {
                return true
            }
            if keepPendingLocalMessages, isPendingLocalMessage(message) {
                return true
            }
            return false
        }
    }

    func applyingHistoryVisibilityBoundary(
        _ boundary: HistoryVisibilityBoundary?,
        to conversation: Conversation?,
        keepPendingLocalMessages: Bool = true
    ) -> Conversation? {
        guard var updated = conversation else { return nil }
        guard updated.kind == .group else { return updated }
        let resolvedBoundary = boundary ?? HistoryVisibilityBoundary(fromSeq: 1, limited: false, confirmed: true)
        let previousBoundarySeq = (updated.historyBoundaryConfirmed || updated.historyVisibleFromSeq > 1 || updated.historyLimited)
            ? max(1, updated.historyVisibleFromSeq)
            : nil
        let shouldClearForNewEpisode = previousBoundarySeq.map { resolvedBoundary.fromSeq < $0 } ?? false
        updated.historyVisibleFromSeq = resolvedBoundary.fromSeq
        updated.historyLimited = resolvedBoundary.limited
        updated.historyBoundaryConfirmed = resolvedBoundary.confirmed
        if shouldClearForNewEpisode {
            updated.messages = keepPendingLocalMessages ? updated.messages.filter { isPendingLocalMessage($0) } : []
        } else {
            updated.messages = historyVisibleMessages(
                updated.messages,
                boundary: resolvedBoundary,
                keepPendingLocalMessages: keepPendingLocalMessages
            )
        }
        refreshHistoryBoundedSummary(&updated, boundary: resolvedBoundary)
        return updated
    }

    @discardableResult
    func applyHistoryVisibilityBoundary(
        channelID: String,
        boundary: HistoryVisibilityBoundary,
        channelIDForConversation: (Conversation) -> String
    ) -> Bool {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty,
              let index = conversations.firstIndex(where: { conversation in
                  conversation.id == normalizedChannelID || channelIDForConversation(conversation) == normalizedChannelID
              }),
              let updated = applyingHistoryVisibilityBoundary(boundary, to: conversations[index]) else { return false }
        var next = conversations
        next[index] = updated
        return publishConversationsIfChanged(next)
    }

    private func refreshHistoryBoundedSummary(_ conversation: inout Conversation, boundary: HistoryVisibilityBoundary) {
        if let latest = latestConfirmedMessage(in: conversation.messages.filter { !$0.isPinnedContextOnly })
            ?? latestConfirmedMessage(in: conversation.messages) {
            conversation.lastMessage = messageListPreview(latest)
            conversation.time = latest.time
            conversation.sortTimestamp = effectiveCreatedAt(for: latest)?.timeIntervalSince1970 ?? conversation.sortTimestamp
        } else if boundary.isRestrictive || conversation.historyBoundaryConfirmed {
            conversation.lastMessage = ""
            conversation.time = ""
            conversation.sortTimestamp = 0
        }
        if boundary.isRestrictive {
            if conversation.firstUnreadSeq > 0 && conversation.firstUnreadSeq < boundary.fromSeq {
                conversation.unread = 0
                conversation.firstUnreadSeq = 0
                conversation.firstUnreadMessageID = ""
                conversation.unreadAnchorSeq = 0
                conversation.unreadAnchorState = "none"
            }
            if conversation.mentionSummaryChannelSeq > 0 && conversation.mentionSummaryChannelSeq < boundary.fromSeq {
                conversation.hasMention = false
                conversation.mentionCount = 0
                conversation.mentionSummaryText = ""
                conversation.mentionSummaryMessageID = ""
                conversation.mentionSummaryChannelSeq = 0
            }
            if conversation.messages.isEmpty {
                conversation.unread = 0
                conversation.hasUnreadReaction = false
                conversation.unreadReactionCount = 0
                conversation.hasMention = false
                conversation.mentionCount = 0
            }
        }
    }

    @discardableResult
    func deleteConversation(conversationID: String) -> Conversation? {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == normalizedID }) else { return nil }
        return conversations.remove(at: index)
    }

    @discardableResult
    func insertDirectConversation(
        channelID: String,
        title: String,
        participant: IMUser,
        accentHex: UInt
    ) -> Conversation? {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else { return nil }
        if let existing = conversations.first(where: { $0.id == normalizedChannelID }) {
            return existing
        }
        let conversation = Conversation(
            id: normalizedChannelID,
            title: title,
            subtitle: "单聊",
            kind: .direct,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 0,
            accentHex: accentHex,
            participants: [participant],
            messages: [],
            avatarURL: participant.avatarURL,
            avatarVersion: participant.avatarVersion,
            avatarUpdatedAt: participant.avatarUpdatedAt
        )
        conversations.insert(conversation, at: 0)
        return conversation
    }

    func conversationsByChannelID(channelIDForConversation: (Conversation) -> String) -> [String: Conversation] {
        // JHT_MOD_BEGIN CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改开始：手动建索引避免 Dictionary(grouping:) 为每个 channel 分配临时数组
        Self.indexedConversations(conversations, channelIDForConversation: channelIDForConversation)
        // JHT_MOD_END CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改结束
    }

    // JHT_MOD_BEGIN CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改开始：保留旧语义，只记录每个 channel 的第一条会话
    private static func indexedConversations(
        _ rows: [Conversation],
        channelIDForConversation: (Conversation) -> String
    ) -> [String: Conversation] {
        var result: [String: Conversation] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let channelID = channelIDForConversation(row)
            if result[channelID] == nil {
                result[channelID] = row
            }
        }
        return result
    }
    // JHT_MOD_END CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改结束

    func conversationListPrecedes(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        let lhsTimestamp = conversationSortTimestamp(lhs)
        let rhsTimestamp = conversationSortTimestamp(rhs)
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp > rhsTimestamp }
        return lhs.id < rhs.id
    }

    func toggleConversationPinned(conversationID: String) -> ConversationSettingChange? {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        let previousValue = conversations[index].isPinned
        conversations[index].isPinned.toggle()
        let conversation = conversations[index]
        conversations.sort(by: conversationListPrecedes)
        return ConversationSettingChange(previousValue: previousValue, conversation: conversation)
    }

    func restoreConversationPinned(conversationID: String, to previousValue: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isPinned = previousValue
        conversations.sort(by: conversationListPrecedes)
    }

    func toggleConversationMuted(conversationID: String) -> ConversationSettingChange? {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        let previousValue = conversations[index].isMuted
        conversations[index].isMuted.toggle()
        return ConversationSettingChange(previousValue: previousValue, conversation: conversations[index])
    }

    func restoreConversationMuted(conversationID: String, to previousValue: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].isMuted = previousValue
    }

    @discardableResult
    func setGroupConversationMuted(groupID: String, groupName: String, isMuted: Bool) -> Bool {
        let normalizedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty || !normalizedName.isEmpty else { return false }
        guard let index = conversations.firstIndex(where: { conversation in
            (!normalizedID.isEmpty && conversation.id == normalizedID)
                || (!normalizedName.isEmpty && conversation.title == normalizedName)
        }) else { return false }
        conversations[index].isMuted = isMuted
        return true
    }

    @discardableResult
    func updateGroupAllMutedConversationPreview(
        groupID: String,
        groupName: String,
        message: String,
        time: String = "刚刚",
        channelIDForConversation: (Conversation) -> String
    ) -> Bool {
        let normalizedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty || !normalizedName.isEmpty else { return false }
        guard let index = conversations.firstIndex(where: { conversation in
            (!normalizedID.isEmpty && conversation.id == normalizedID)
                || (!normalizedID.isEmpty && channelIDForConversation(conversation) == normalizedID)
                || (!normalizedName.isEmpty && conversation.kind == .group && conversation.title == normalizedName)
        }) else { return false }
        conversations[index].lastMessage = message
        conversations[index].time = time
        return true
    }

    @discardableResult
    func removeParticipantFromGroupConversation(
        groupID: String,
        groupName: String,
        userID: String,
        memberCount: Int?
    ) -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty,
              !normalizedGroupID.isEmpty || !normalizedGroupName.isEmpty else { return false }
        guard let index = conversations.firstIndex(where: { conversation in
            (!normalizedGroupID.isEmpty && conversation.id == normalizedGroupID)
                || (!normalizedGroupName.isEmpty && conversation.title == normalizedGroupName)
        }) else { return false }
        conversations[index].participants.removeAll { $0.id == normalizedUserID }
        conversations[index].memberCount = memberCount
        return true
    }

    @discardableResult
    func removeParticipantFromAllConversations(userID: String) -> Int {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty else { return 0 }
        var removedCount = 0
        for index in conversations.indices {
            let beforeCount = conversations[index].participants.count
            conversations[index].participants.removeAll { $0.id == normalizedUserID }
            removedCount += beforeCount - conversations[index].participants.count
        }
        return removedCount
    }

    @discardableResult
    func updateConversationParticipants(_ transform: (IMUser) -> IMUser) -> Int {
        var updatedCount = 0
        for index in conversations.indices {
            guard !conversations[index].participants.isEmpty else { continue }
            var nextParticipants: [IMUser] = []
            nextParticipants.reserveCapacity(conversations[index].participants.count)
            for participant in conversations[index].participants {
                let updatedParticipant = transform(participant)
                if updatedParticipant != participant {
                    updatedCount += 1
                }
                nextParticipants.append(updatedParticipant)
            }
            if nextParticipants != conversations[index].participants {
                conversations[index].participants = nextParticipants
            }
        }
        return updatedCount
    }

    // JHT_MOD_BEGIN APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改开始：头像投影只复制命中的会话/消息，避免整表拷贝和深比较
    struct AvatarRealtimeConversationProjection {
        let uid: String
        let url: String
        let cacheVersion: String
        let updatedAt: String
    }

    struct AvatarRealtimeConversationApplyResult {
        let conversationsChanged: Int
        let participantsChanged: Int
        let messagesChanged: Int

        static let empty = AvatarRealtimeConversationApplyResult(
            conversationsChanged: 0,
            participantsChanged: 0,
            messagesChanged: 0
        )

        var didChange: Bool {
            conversationsChanged > 0
        }
    }

    @discardableResult
    func applyAvatarRealtimeProjectionsToConversations(
        _ projections: [String: AvatarRealtimeConversationProjection],
        currentUID: String,
        channelIDForConversation: (Conversation) -> String,
        projectParticipant: (IMUser) -> IMUser
    ) -> AvatarRealtimeConversationApplyResult {
        guard !projections.isEmpty else { return .empty }
        let projectionUIDs = Set(projections.keys)
        var updatedConversations = conversations
        var conversationsChanged = 0
        var participantsChanged = 0
        var messagesChanged = 0

        for index in updatedConversations.indices {
            var conversation = updatedConversations[index]
            var conversationDidChange = false

            if !conversation.participants.isEmpty {
                var nextParticipants = conversation.participants
                var participantsDidChange = false
                for participantIndex in nextParticipants.indices {
                    guard projectionUIDs.contains(nextParticipants[participantIndex].id) else { continue }
                    let updatedParticipant = projectParticipant(nextParticipants[participantIndex])
                    guard updatedParticipant != nextParticipants[participantIndex] else { continue }
                    nextParticipants[participantIndex] = updatedParticipant
                    participantsDidChange = true
                    participantsChanged += 1
                }
                if participantsDidChange {
                    conversation.participants = nextParticipants
                    conversationDidChange = true
                }
            }

            if !conversation.messages.isEmpty {
                var nextMessages = conversation.messages
                var messagesDidChange = false
                for messageIndex in nextMessages.indices {
                    let senderID = nextMessages[messageIndex].senderId
                    guard let projection = projections[senderID] else { continue }
                    var message = nextMessages[messageIndex]
                    var messageDidChange = false
                    if message.senderAvatarURL != projection.url {
                        message.senderAvatarURL = projection.url
                        messageDidChange = true
                    }
                    if message.senderAvatarVersion != projection.cacheVersion {
                        message.senderAvatarVersion = projection.cacheVersion
                        messageDidChange = true
                    }
                    if !projection.updatedAt.isEmpty,
                       message.senderAvatarUpdatedAt != projection.updatedAt {
                        message.senderAvatarUpdatedAt = projection.updatedAt
                        messageDidChange = true
                    }
                    guard messageDidChange else { continue }
                    nextMessages[messageIndex] = message
                    messagesDidChange = true
                    messagesChanged += 1
                }
                if messagesDidChange {
                    conversation.messages = nextMessages
                    conversationDidChange = true
                }
            }

            if conversation.kind == .direct {
                let remoteChannelID = channelIDForConversation(conversation)
                let participantUIDs = conversation.participants.map(\.id)
                if let peerUID = AvatarRealtimeSurfaceProjector.directPeerUID(
                    conversationID: conversation.id,
                    remoteChannelID: remoteChannelID,
                    participantUIDs: participantUIDs,
                    currentUID: currentUID
                ), let projection = projections[peerUID] {
                    if conversation.avatarURL != projection.url {
                        conversation.avatarURL = projection.url
                        conversationDidChange = true
                    }
                    if conversation.avatarVersion != projection.cacheVersion {
                        conversation.avatarVersion = projection.cacheVersion
                        conversationDidChange = true
                    }
                    if !projection.updatedAt.isEmpty,
                       conversation.avatarUpdatedAt != projection.updatedAt {
                        conversation.avatarUpdatedAt = projection.updatedAt
                        conversationDidChange = true
                    }
                }
            }

            if conversationDidChange {
                updatedConversations[index] = conversation
                conversationsChanged += 1
            }
        }

        guard conversationsChanged > 0 else { return .empty }
        conversations = updatedConversations
        return AvatarRealtimeConversationApplyResult(
            conversationsChanged: conversationsChanged,
            participantsChanged: participantsChanged,
            messagesChanged: messagesChanged
        )
    }
    // JHT_MOD_END APPSTATE_AVATAR_CONVERSATION_TARGETED_APPLY_PERF_20260912 - 修改结束

    @discardableResult
    func refreshDirectConversationProfiles(
        channelIDForConversation: (Conversation) -> String,
        titleForChannel: (String) -> String,
        participantsForChannel: (String) -> [IMUser]
    ) -> Int {
        var updatedConversationCount = 0
        var updatedConversations = conversations
        for index in updatedConversations.indices where updatedConversations[index].kind == .direct {
            var didUpdate = false
            let channelID = channelIDForConversation(updatedConversations[index])
            let resolvedTitle = titleForChannel(channelID)
            if !resolvedTitle.isEmpty && resolvedTitle != updatedConversations[index].title {
                updatedConversations[index].title = resolvedTitle
                didUpdate = true
            }

            let participants = participantsForChannel(channelID)
            if !participants.isEmpty {
                if participants != updatedConversations[index].participants {
                    updatedConversations[index].participants = participants
                    didUpdate = true
                }
                if let avatarUser = participants.first, !avatarUser.avatarURL.isEmpty {
                    if updatedConversations[index].avatarURL != avatarUser.avatarURL {
                        updatedConversations[index].avatarURL = avatarUser.avatarURL
                        didUpdate = true
                    }
                    if updatedConversations[index].avatarVersion != avatarUser.avatarVersion {
                        updatedConversations[index].avatarVersion = avatarUser.avatarVersion
                        didUpdate = true
                    }
                    if updatedConversations[index].avatarUpdatedAt != avatarUser.avatarUpdatedAt {
                        updatedConversations[index].avatarUpdatedAt = avatarUser.avatarUpdatedAt
                        didUpdate = true
                    }
                }
            }

            if didUpdate {
                updatedConversationCount += 1
            }
        }
        if updatedConversationCount > 0 {
            conversations = updatedConversations
        }
        return updatedConversationCount
    }

    @discardableResult
    func setGroupConversationParticipants(
        groupID: String,
        groupName: String,
        participants: [IMUser],
        memberCount: Int?
    ) -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty || !normalizedGroupName.isEmpty else { return false }
        guard let index = conversations.firstIndex(where: { conversation in
            (!normalizedGroupID.isEmpty && conversation.id == normalizedGroupID)
                || (!normalizedGroupName.isEmpty && conversation.title == normalizedGroupName)
        }) else { return false }
        if !participants.isEmpty {
            conversations[index].participants = participants
        }
        conversations[index].memberCount = resolvedGroupMemberCount(
            incoming: memberCount,
            existing: conversations[index].memberCount,
            participants: participants
        )
        return true
    }

    @discardableResult
    func upsertCreatedGroupConversation(
        groupID: String,
        name: String,
        members: [IMUser],
        invitedMemberCount: Int,
        accentHex: UInt,
        sortTimestamp: TimeInterval = Date().timeIntervalSince1970,
        channelIDForConversation: (Conversation) -> String
    ) -> Conversation? {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else { return nil }

        if let index = groupConversationIndex(
            groupID: normalizedGroupID,
            groupName: "",
            matchByTitle: false,
            channelIDForConversation: channelIDForConversation
        ) {
            var conversation = conversations[index]
            conversation.title = name
            conversation.subtitle = "群聊"
            conversation.memberCount = max(conversation.memberCount ?? 0, members.count)
            if !members.isEmpty {
                conversation.participants = members
            }
            conversations[index] = conversation
            return conversation
        }

        let conversation = Conversation(
            id: normalizedGroupID,
            title: name,
            subtitle: "群聊",
            kind: .group,
            lastMessage: "群聊已创建",
            time: "刚刚",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: max(members.count, invitedMemberCount + 1),
            accentHex: accentHex,
            participants: members,
            messages: [],
            avatarURL: "",
            sortTimestamp: sortTimestamp
        )
        conversations.insert(conversation, at: 0)
        return conversation
    }

    @discardableResult
    func ensureGroupConversation(
        groupID: String,
        name: String,
        notice: String,
        members: [IMUser],
        muted: Bool,
        memberCount: Int?,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        avatarIsAuthoritative: Bool = false,
        accentHex: UInt,
        channelIDForConversation: (Conversation) -> String
    ) -> Conversation? {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty || !normalizedName.isEmpty else { return nil }

        if let index = groupConversationIndex(
            groupID: normalizedGroupID,
            groupName: normalizedName,
            matchByTitle: true,
            channelIDForConversation: channelIDForConversation
        ) {
            var conversation = conversations[index]
            conversation.title = name
            conversation.subtitle = "群聊"
            if conversation.lastMessage.isEmpty {
                conversation.lastMessage = notice
            }
            conversation.memberCount = resolvedGroupMemberCount(
                incoming: memberCount,
                existing: conversation.memberCount,
                participants: members
            )
            if !members.isEmpty {
                conversation.participants = members
            }
            if avatarIsAuthoritative {
                conversation.avatarURL = avatarURL
                conversation.avatarVersion = avatarVersion
                conversation.avatarUpdatedAt = avatarUpdatedAt
            } else {
                if !avatarURL.isEmpty {
                    conversation.avatarURL = avatarURL
                }
                if !avatarVersion.isEmpty {
                    conversation.avatarVersion = avatarVersion
                }
                if !avatarUpdatedAt.isEmpty {
                    conversation.avatarUpdatedAt = avatarUpdatedAt
                }
            }
            conversations[index] = conversation
            return conversation
        }

        guard !normalizedGroupID.isEmpty else { return nil }
        let conversation = Conversation(
            id: normalizedGroupID,
            title: name,
            subtitle: "群聊",
            kind: .group,
            lastMessage: notice,
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: muted,
            memberCount: resolvedGroupMemberCount(incoming: memberCount, existing: nil, participants: members),
            accentHex: accentHex,
            participants: members,
            messages: [],
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt
        )
        conversations.append(conversation)
        return conversation
    }

    func latestReadableSequence(in conversation: Conversation) -> Int64 {
        messageSequenceCoveredThrough(in: conversation)
    }

    func messageSequenceCoveredThrough(in conversation: Conversation) -> Int64 {
        let explicitCoverage = max(0, conversation.messageCoveredThroughSeq)
        if conversation.messageCoverageRequiresRecovery {
            return explicitCoverage
        }
        return max(explicitCoverage, inferredMessageSequenceCoverage(conversation.messages))
    }

    func messageSequenceRecoveryTarget(for conversation: Conversation) -> MessageSequenceRecoveryTarget? {
        let coveredThrough = messageSequenceCoveredThrough(in: conversation)
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免为最大序号生成临时数组
        let observedThrough = max(
            conversation.lastMsgSeq,
            ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
        )
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        guard observedThrough > coveredThrough else { return nil }
        return MessageSequenceRecoveryTarget(afterSeq: coveredThrough, throughSeq: observedThrough)
    }

    private func resolvedGroupMemberCount(incoming: Int?, existing: Int?, participants: [IMUser]) -> Int? {
        guard let incoming else { return nil }
        if incoming > 0 { return incoming }
        if let existing, existing > 0 { return existing }
        return participants.isEmpty ? nil : participants.count
    }

    func latestConfirmedMessage(in messages: [ChatMessage]) -> ChatMessage? {
        messages.last { message in
            message.status != .failed && message.status != .sending && !message.isDeletedLocally
        }
    }

    func messageListPreview(_ message: ChatMessage) -> String {
        switch message.kind {
        case .rtcCallRecord:
            return message.rtcCallRecord?.presentation(viewerIsCaller: message.isOutgoing).conversationPreview
                ?? RTCCallRecordPayload.safeFallbackText(payload: [:])
        case .image:
            return "[图片] \(message.attachmentName ?? message.text)"
        case .file:
            switch attachmentMediaCategory(for: message) {
            case "video":
                return "[视频] \(message.attachmentName ?? message.text)"
            case "pdf":
                return "[PDF] \(message.attachmentName ?? message.text)"
            default:
                break
            }
            return "[文件] \(message.attachmentName ?? message.text)"
        case .voice:
            return "[语音] \(message.text)"
        case .video:
            return "[视频] \(message.text)"
        case .location:
            return "[位置] \(message.text)"
        case .contactCard:
            return message.text
        case .system, .text:
            return message.text
        }
    }

    func updateConversationLatestFromMessages(at index: Int) {
        guard conversations.indices.contains(index),
              let latest = latestConfirmedMessage(in: conversations[index].messages) else { return }
        conversations[index].lastMessage = messageListPreview(latest)
        conversations[index].time = latest.time
        conversations[index].sortTimestamp = max(conversations[index].sortTimestamp, effectiveCreatedAt(for: latest)?.timeIntervalSince1970 ?? 0)
    }

    @discardableResult
    func appendLocalOutgoingMessage(
        _ message: ChatMessage,
        to conversationID: String,
        preview: String? = nil,
        displayTime: String = "刚刚"
    ) -> Conversation? {
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == normalizedConversationID }) else { return nil }
        conversations[index].messages.append(message)
        conversations[index].lastMessage = preview ?? messageListPreview(message)
        conversations[index].time = displayTime
        conversations[index].sortTimestamp = effectiveCreatedAt(for: message)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        return conversations[index]
    }

    @discardableResult
    func mergePersistedMessagePage(_ page: [ChatMessage], conversationID: String) -> Int {
        guard !page.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return 0 }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PERSISTED_PREPEND_FAST_PATH_APPLY - 修改开始：本地旧消息分页优先增量合并，减少下拉加载时全量排序
        if let inserted = mergePersistedMessagePageByPrependingIfPossible(
            page,
            conversationID: conversationID,
            at: index
        ) {
            return inserted
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PERSISTED_PREPEND_FAST_PATH_APPLY - 修改结束：本地旧消息分页优先增量合并，减少下拉加载时全量排序
        var identifiers = Set(conversations[index].messages.map(\.id))
        var sequences = Set(conversations[index].messages.map(\.channelSeq).filter { $0 > 0 })
        var rtcAuthorityByCallID: [String: (conversationID: String, authority: RTCCallRecordMessageDeduplicator.Authority)] = [:]
        for conversation in conversations {
            for existingMessage in conversation.messages {
                guard let authority = RTCCallRecordMessageDeduplicator.authority(for: existingMessage),
                      rtcAuthorityByCallID[authority.callID] == nil else { continue }
                rtcAuthorityByCallID[authority.callID] = (conversation.id, authority)
            }
        }
        var inserted = 0
        for message in page {
            if let authority = RTCCallRecordMessageDeduplicator.authority(for: message),
               let existing = rtcAuthorityByCallID[authority.callID] {
                if existing.conversationID != conversationID || existing.authority != authority,
                   authority.channelSeq > 0 {
                    conversations[index].messageCoveredThroughSeq = min(
                        conversations[index].messageCoveredThroughSeq,
                        max(0, authority.channelSeq - 1)
                    )
                    conversations[index].messageCoverageRequiresRecovery = true
                }
                continue
            }
            guard !identifiers.contains(message.id),
                  message.channelSeq <= 0 || !sequences.contains(message.channelSeq) else { continue }
            conversations[index].messages.append(message)
            identifiers.insert(message.id)
            if let authority = RTCCallRecordMessageDeduplicator.authority(for: message) {
                rtcAuthorityByCallID[authority.callID] = (conversationID, authority)
            }
            if message.channelSeq > 0 {
                sequences.insert(message.channelSeq)
            }
            inserted += 1
        }
        if inserted > 0 {
            conversations[index].messages.sort(by: messageTimelinePrecedes)
        }
        return inserted
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_PERSISTED_PREPEND_FAST_PATH_HELPER - 修改开始：本地旧消息分页只在安全条件下线性合并
    private func mergePersistedMessagePageByPrependingIfPossible(
        _ page: [ChatMessage],
        conversationID: String,
        at index: Int
    ) -> Int? {
        let currentMessages = conversations[index].messages
        guard !currentMessages.isEmpty,
              messagesAreTimelineSorted(currentMessages) else {
            return nil
        }
        let oldestExistingSeq = currentMessages
            .lazy
            .map(\.channelSeq)
            .filter { $0 > 0 }
            .min() ?? 0
        guard oldestExistingSeq > 0 else { return nil }

        var incomingIDs = Set<String>()
        var incomingSeqs = Set<Int64>()
        var incomingMessages: [ChatMessage] = []
        incomingMessages.reserveCapacity(page.count)
        for message in page {
            let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageID.isEmpty,
                  message.channelSeq > 0,
                  message.channelSeq < oldestExistingSeq,
                  RTCCallRecordMessageDeduplicator.authority(for: message) == nil else {
                return nil
            }
            guard !incomingIDs.contains(messageID),
                  !incomingSeqs.contains(message.channelSeq) else {
                continue
            }
            incomingIDs.insert(messageID)
            incomingSeqs.insert(message.channelSeq)
            incomingMessages.append(message)
        }
        guard !incomingMessages.isEmpty else { return 0 }

        var existingIncomingIDs = Set<String>()
        var existingIncomingSeqs = Set<Int64>()
        for message in currentMessages {
            let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if incomingIDs.contains(messageID) {
                existingIncomingIDs.insert(messageID)
            }
            if message.channelSeq > 0, incomingSeqs.contains(message.channelSeq) {
                existingIncomingSeqs.insert(message.channelSeq)
            }
        }

        incomingMessages.removeAll { message in
            existingIncomingIDs.contains(message.id.trimmingCharacters(in: .whitespacesAndNewlines))
                || existingIncomingSeqs.contains(message.channelSeq)
        }
        guard !incomingMessages.isEmpty else { return 0 }

        incomingMessages.sort(by: messageTimelinePrecedes)
        conversations[index].messages = mergedTimelineMessages(incomingMessages, currentMessages)
        return incomingMessages.count
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_PERSISTED_PREPEND_FAST_PATH_HELPER - 修改结束：本地旧消息分页只在安全条件下线性合并

    @discardableResult
    func applyLocalMessageEdit(messageID: String, conversationID: String, text: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              !trimmedText.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].text = trimmedText
        conversations[cIndex].messages[mIndex].isEdited = true
        conversations[cIndex].messages[mIndex].status = .sent
        conversations[cIndex].lastMessage = trimmedText
        return true
    }

    @discardableResult
    func markAttachmentUploadFailed(
        messageID: String,
        conversationID: String,
        failureStatus: String = "failed",
        failure: AttachmentUploadFailure? = nil
    ) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].status = .failed
        let normalizedFailureStatus = failureStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        conversations[cIndex].messages[mIndex].attachmentUploadStatus = normalizedFailureStatus.isEmpty ? "failed" : normalizedFailureStatus
        conversations[cIndex].messages[mIndex].attachmentUploadFailure = failure
        return true
    }

    @discardableResult
    func updateAttachmentUploadStatus(
        _ status: String,
        messageID: String,
        conversationID: String
    ) -> ChatMessage? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              !normalizedStatus.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        conversations[cIndex].messages[mIndex].attachmentUploadStatus = normalizedStatus
        conversations[cIndex].messages[mIndex].attachmentUploadFailure = nil
        return conversations[cIndex].messages[mIndex]
    }

    @discardableResult
    func markAttachmentUploadRetrying(messageID: String, conversationID: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].status = .sending
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_RETRY - 修改开始：重试阶段只更新状态，不写假百分比
        conversations[cIndex].messages[mIndex].attachmentTransferProgress = nil
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_RETRY - 修改结束
        conversations[cIndex].messages[mIndex].attachmentUploadStatus = "retrying"
        conversations[cIndex].messages[mIndex].attachmentUploadFailure = nil
        return true
    }

    func messagePinnedState(messageID: String, conversationID: String) -> Bool? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        return conversations[cIndex].messages[mIndex].isPinned
    }

    @discardableResult
    func setMessagePinned(messageID: String, conversationID: String, pinned: Bool) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].isPinned = pinned
        return true
    }

    func messageFavoritedState(messageID: String, conversationID: String) -> Bool? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        return conversations[cIndex].messages[mIndex].isFavorited
    }

    @discardableResult
    func setMessageFavorited(messageID: String, conversationID: String, favorited: Bool) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].isFavorited = favorited
        return true
    }

    @discardableResult
    func setMessageReportState(messageID: String, conversationID: String, reason: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].reportState = reason
        return true
    }

    @discardableResult
    func markMessageResendFailed(messageID: String, conversationID: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].status = .failed
        return true
    }

    @discardableResult
    func markMessageFailed(messageID: String, conversationID: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
        conversations[cIndex].messages[mIndex].status = .failed
        updateConversationLatestFromMessages(at: cIndex)
        return true
    }

    @discardableResult
    func removeMessage(messageID: String, conversationID: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }) else { return false }
        let originalCount = conversations[cIndex].messages.count
        conversations[cIndex].messages.removeAll { $0.id == normalizedMessageID }
        guard conversations[cIndex].messages.count != originalCount else { return false }
        updateConversationLatestFromMessages(at: cIndex)
        return true
    }

    @discardableResult
    func setAttachmentFileID(_ fileID: String, messageID: String, conversationID: String) -> ChatMessage? {
        let normalizedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileID.isEmpty,
              !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        conversations[cIndex].messages[mIndex].attachmentFileID = normalizedFileID
        return conversations[cIndex].messages[mIndex]
    }

    @discardableResult
    func updateAttachmentProgress(_ progress: Double?, messageID: String, conversationID: String) -> ChatMessage? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_APPLY - 修改开始：上传进度小幅高频变化不反复写消息数组，降低图片/附件消息滑动卡顿
        let throttleKey = attachmentProgressThrottleKey(
            conversationID: normalizedConversationID,
            messageID: normalizedMessageID
        )
        let currentProgress = conversations[cIndex].messages[mIndex].attachmentTransferProgress
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
            conversations[cIndex].messages[mIndex].attachmentTransferProgress = boundedProgress
        } else {
            attachmentProgressPublishSnapshotsByKey[throttleKey] = nil
            guard currentProgress != nil else { return conversations[cIndex].messages[mIndex] }
            conversations[cIndex].messages[mIndex].attachmentTransferProgress = nil
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_ATTACHMENT_UPLOAD_PROGRESS_THROTTLE_APPLY - 修改结束：上传进度小幅高频变化不反复写消息数组，降低图片/附件消息滑动卡顿
        return conversations[cIndex].messages[mIndex]
    }

    @discardableResult
    func updateMessageAttachment(_ message: ChatMessage, conversationID: String) -> ChatMessage? {
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        conversations[cIndex].messages[mIndex].attachmentName = message.attachmentName
        conversations[cIndex].messages[mIndex].attachmentMeta = message.attachmentMeta
        conversations[cIndex].messages[mIndex].attachmentFileID = message.attachmentFileID
        conversations[cIndex].messages[mIndex].attachmentSizeBytes = message.attachmentSizeBytes
        conversations[cIndex].messages[mIndex].attachmentPreviewURL = message.attachmentPreviewURL
        conversations[cIndex].messages[mIndex].attachmentDownloadURL = message.attachmentDownloadURL
        conversations[cIndex].messages[mIndex].attachmentPreviewAvailable = message.attachmentPreviewAvailable
        conversations[cIndex].messages[mIndex].attachmentDownloadAvailable = message.attachmentDownloadAvailable
        conversations[cIndex].messages[mIndex].attachmentTransferProgress = message.attachmentTransferProgress
        conversations[cIndex].messages[mIndex].attachmentMimeType = message.attachmentMimeType
        conversations[cIndex].messages[mIndex].attachmentCacheKey = message.attachmentCacheKey
        conversations[cIndex].messages[mIndex].attachmentVersion = message.attachmentVersion
        conversations[cIndex].messages[mIndex].attachmentChecksum = message.attachmentChecksum
        conversations[cIndex].messages[mIndex].attachmentMediaCategory = message.attachmentMediaCategory
        conversations[cIndex].messages[mIndex].attachmentExtension = message.attachmentExtension
        conversations[cIndex].messages[mIndex].attachmentThumbnailURL = message.attachmentThumbnailURL
        conversations[cIndex].messages[mIndex].attachmentPosterURL = message.attachmentPosterURL
        conversations[cIndex].messages[mIndex].attachmentCoverURL = message.attachmentCoverURL
        conversations[cIndex].messages[mIndex].attachmentPreviewKind = message.attachmentPreviewKind
        conversations[cIndex].messages[mIndex].attachmentContentDisposition = message.attachmentContentDisposition
        conversations[cIndex].messages[mIndex].attachmentWidth = message.attachmentWidth
        conversations[cIndex].messages[mIndex].attachmentHeight = message.attachmentHeight
        conversations[cIndex].messages[mIndex].attachmentDurationSeconds = message.attachmentDurationSeconds
        conversations[cIndex].messages[mIndex].attachmentUploadStatus = message.attachmentUploadStatus
        conversations[cIndex].messages[mIndex].attachmentUploadFailure = message.attachmentUploadFailure
        updateConversationLatestFromMessages(at: cIndex)
        return conversations[cIndex].messages[mIndex]
    }

    /// 历史窗口扩展(如跳转置顶/搜索目标前的水合)后,把已落入加载窗口的
    /// 置顶上下文消息恢复为普通时间线行,否则时间线渲染仍会把它过滤掉,
    /// scrollTo 找不到对应行导致定位失败。
    func normalizePinnedContextMessagesWithinLoadedWindow(conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let oldestLoadedTimelineSeq = conversations[index].messages
            .filter { message in
                !message.isPinned
                    && !message.isPinnedContextOnly
                    && message.channelSeq > 0
                    && message.status != .sending
                    && message.status != .failed
            }
            .map(\.channelSeq)
            .min()
        guard let oldestLoadedTimelineSeq else { return }
        for mIndex in conversations[index].messages.indices {
            if conversations[index].messages[mIndex].isPinnedContextOnly,
               conversations[index].messages[mIndex].channelSeq >= oldestLoadedTimelineSeq {
                conversations[index].messages[mIndex].isPinnedContextOnly = false
            }
        }
    }

    func applyingPinnedMessageSnapshot(
        _ entries: [PinnedMessageSnapshotEntry],
        to conversation: Conversation
    ) -> Conversation {
        var updated = conversation
        let boundary = historyBoundary(for: conversation)
        let activeEntries = entries.compactMap { entry -> (id: String, message: ChatMessage)? in
            let normalizedID = entry.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = entry.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, status != "recalled", status != "deleted" else { return nil }
            guard historyVisibleMessages([entry.message], boundary: boundary, keepPendingLocalMessages: false).isEmpty == false else { return nil }
            return (normalizedID, entry.message)
        }
        let pinnedIDs = Set(activeEntries.map(\.id))
        updated.messages.removeAll { message in
            message.isPinnedContextOnly && !pinnedIDs.contains(message.id)
        }
        let oldestLoadedTimelineSeq = updated.messages
            .filter { message in
                !message.isPinned
                    && !message.isPinnedContextOnly
                    && message.channelSeq > 0
                    && message.status != .sending
                    && message.status != .failed
            }
            .map(\.channelSeq)
            .min()
        for index in updated.messages.indices {
            let isPinned = pinnedIDs.contains(updated.messages[index].id)
            updated.messages[index].isPinned = isPinned
            if isPinned,
               let oldestLoadedTimelineSeq,
               updated.messages[index].channelSeq > 0,
               updated.messages[index].channelSeq < oldestLoadedTimelineSeq {
                updated.messages[index].isPinnedContextOnly = true
            } else if !isPinned {
                updated.messages[index].isPinnedContextOnly = false
            }
        }
        let existingIDs = Set(updated.messages.map(\.id))
        let missingPinnedMessages = activeEntries
            .filter { !existingIDs.contains($0.id) }
            .map { entry -> ChatMessage in
                var message = entry.message
                message.isPinned = true
                message.isPinnedContextOnly = true
                return message
            }
        guard !missingPinnedMessages.isEmpty else { return updated }
        updated.messages.append(contentsOf: missingPinnedMessages)
        updated.messages.sort { lhs, rhs in
            if lhs.channelSeq != rhs.channelSeq {
                return lhs.channelSeq < rhs.channelSeq
            }
            return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }
        return updated
    }

    @discardableResult
    func applyPinnedMessageSnapshot(
        _ entries: [PinnedMessageSnapshotEntry],
        conversationID: String
    ) -> Conversation? {
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == normalizedConversationID }) else { return nil }
        let updated = applyingPinnedMessageSnapshot(entries, to: conversations[index])
        conversations[index] = updated
        return updated
    }

    @discardableResult
    func setContactCardAttachmentMeta(messageID: String, conversationID: String, contactID: String) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContactID = contactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              !normalizedContactID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }),
              conversations[cIndex].messages[mIndex].kind == .contactCard else { return false }
        conversations[cIndex].messages[mIndex].attachmentMeta = normalizedContactID
        return true
    }

    @discardableResult
    func prepareMessageForResend(
        messageID: String,
        conversationID: String,
        createdAt: Date = Date(),
        readBy: [ReadReceipt]
    ) -> ChatMessage? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        conversations[cIndex].messages[mIndex].status = .sending
        conversations[cIndex].messages[mIndex].createdAt = createdAt
        conversations[cIndex].messages[mIndex].readBy = readBy
        return conversations[cIndex].messages[mIndex]
    }

    @discardableResult
    func resolveGroupInviteApprovalMessages(
        requestID: String,
        status: String,
        approverName: String = "",
        approverAccountID: String = "",
        decidedAt: String = "",
        resultText: String = ""
    ) -> Int {
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequestID.isEmpty else { return 0 }
        var updatedCount = 0
        for cIndex in conversations.indices {
            for mIndex in conversations[cIndex].messages.indices {
                guard let approval = conversations[cIndex].messages[mIndex].groupInviteApproval,
                      approval.requestID.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedRequestID else { continue }
                conversations[cIndex].messages[mIndex].groupInviteApproval = approval.resolved(
                    status: status,
                    approverName: approverName,
                    approverAccountID: approverAccountID,
                    decidedAt: decidedAt,
                    resultText: resultText
                )
                updatedCount += 1
            }
        }
        return updatedCount
    }

    @discardableResult
    func applyRecall(
        messageID: String,
        conversationID: String? = nil,
        recallText: String? = nil,
        channelIDForConversation: ((Conversation) -> String)? = nil
    ) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty else { return false }
        let normalizedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for cIndex in conversations.indices {
            if !normalizedConversationID.isEmpty,
               conversations[cIndex].id != normalizedConversationID,
               channelIDForConversation?(conversations[cIndex]) != normalizedConversationID {
                continue
            }
            guard let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { continue }
            markMessageAsRecalled(&conversations[cIndex].messages[mIndex], recallText: recallText)
            updateConversationLatestFromMessages(at: cIndex)
            return true
        }
        return false
    }

    /// 冷读(历史分页/重进会话)时,消息本体 status 已是 recalled 但 payload
    /// 仍保留原文,映射阶段直接按撤回墓碑清洗,不依赖 message-extras 补丁。
    func markMessageAsRecalledFromRemoteStatus(_ message: inout ChatMessage) {
        markMessageAsRecalled(&message, recallText: nil)
    }

    private func markMessageAsRecalled(_ message: inout ChatMessage, recallText: String?) {
        let safeText = recallText?.trimmingCharacters(in: .whitespacesAndNewlines)
        message.status = .recalled
        message.text = safeText?.isEmpty == false ? safeText! : defaultRecallText(for: message)
        message.quote = nil
        message.replyContext = unavailableReplyContext(messageID: message.id)
        message.attachmentName = nil
        message.attachmentMeta = nil
        message.attachmentFileID = nil
        message.attachmentSizeBytes = nil
        message.attachmentPreviewURL = ""
        message.attachmentDownloadURL = ""
        message.attachmentPreviewAvailable = false
        message.attachmentDownloadAvailable = false
        message.attachmentThumbnailURL = ""
        message.attachmentPosterURL = ""
        message.attachmentCoverURL = ""
        message.attachmentTransferProgress = nil
        message.attachmentMimeType = ""
        message.attachmentCacheKey = ""
        message.attachmentVersion = ""
        message.attachmentChecksum = ""
        message.attachmentMediaCategory = ""
        message.attachmentExtension = ""
        message.attachmentPreviewKind = ""
        message.attachmentContentDisposition = ""
        message.attachmentWidth = nil
        message.attachmentHeight = nil
        message.attachmentDurationSeconds = nil
        message.attachmentUploadStatus = ""
        message.attachmentUploadFailure = nil
        message.reactions = []
        message.reactionDetails = []
        message.readBy = []
        message.unreadBy = []
        message.readCount = nil
        message.unreadCount = nil
        message.readStateKnown = false
        message.canViewReadDetails = false
    }

    private func defaultRecallText(for message: ChatMessage) -> String {
        if message.isOutgoing {
            return "你撤回了一条消息"
        }
        let sender = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, sender != "未知用户", sender != "系统" else {
            return "对方撤回了一条消息"
        }
        return "\(sender)撤回了一条消息"
    }

    @discardableResult
    func applyAdminDeletedMessage(
        messageID: String,
        conversationID: String? = nil,
        channelIDForConversation: (Conversation) -> String
    ) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty else { return false }
        for cIndex in conversations.indices {
            if let conversationID,
               conversations[cIndex].id != conversationID,
               channelIDForConversation(conversations[cIndex]) != conversationID {
                continue
            }
            guard let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }) else { continue }
            markMessageAsAdminDeleted(&conversations[cIndex].messages[mIndex])
            updateConversationLatestFromMessages(at: cIndex)
            return true
        }
        return false
    }

    func markMessageAsAdminDeleted(_ message: inout ChatMessage) {
        message.isDeletedLocally = true
        message.status = .recalled
        message.text = "原消息已删除"
        message.quote = nil
        message.replyContext = unavailableReplyContext(messageID: message.id)
        message.attachmentName = nil
        message.attachmentMeta = nil
        message.attachmentFileID = nil
        message.attachmentSizeBytes = nil
        message.attachmentPreviewURL = ""
        message.attachmentDownloadURL = ""
        message.attachmentPreviewAvailable = false
        message.attachmentDownloadAvailable = false
        message.attachmentThumbnailURL = ""
        message.attachmentPosterURL = ""
        message.attachmentCoverURL = ""
        message.attachmentTransferProgress = nil
        message.attachmentMimeType = ""
        message.attachmentCacheKey = ""
        message.attachmentVersion = ""
        message.attachmentChecksum = ""
        message.attachmentMediaCategory = ""
        message.attachmentExtension = ""
        message.attachmentPreviewKind = ""
        message.attachmentContentDisposition = ""
        message.attachmentWidth = nil
        message.attachmentHeight = nil
        message.attachmentDurationSeconds = nil
        message.attachmentUploadStatus = ""
        message.attachmentUploadFailure = nil
        message.reactions = []
        message.reactionDetails = []
        message.readBy = []
        message.unreadBy = []
        message.readCount = nil
        message.unreadCount = nil
        message.readStateKnown = false
        message.canViewReadDetails = false
    }

    @discardableResult
    func mergeRemoteConversationList(
        entries: [RemoteConversationMergeEntry],
        replacing: Bool,
        channelIDForConversation: (Conversation) -> String
    ) -> MergedRemoteConversationsResult {
        let previousByChannelID = conversationsByChannelID(channelIDForConversation: channelIDForConversation)
        var nextByChannelID: [String: Conversation] = replacing ? [:] : previousByChannelID
        for entry in entries {
            nextByChannelID[entry.channelID] = entry.conversation
        }
        let ordered = deduplicatedConversationsByID(Array(nextByChannelID.values)).sorted(by: conversationListPrecedes)
        let merged = conversationsEnforcingGlobalRTCCallRecordExactOnce(ordered)
        // JHT_MOD_BEGIN CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改开始：复用无临时数组索引，降低远端会话合并主线程分配
        let mergedByChannelID = Self.indexedConversations(
            merged,
            channelIDForConversation: channelIDForConversation
        )
        // JHT_MOD_END CONVERSATION_STORE_CHANNEL_INDEX_PERF_20260913 - 修改结束
        let soundCandidates = entries.compactMap { entry -> RemoteConversationSoundCandidate? in
            guard let previous = previousByChannelID[entry.channelID],
                  let normalizedMapped = mergedByChannelID[entry.channelID] else { return nil }
            return RemoteConversationSoundCandidate(
                previous: previous,
                remote: entry.remote,
                mapped: normalizedMapped
            )
        }
        publishConversationsIfChanged(merged)
        return MergedRemoteConversationsResult(conversations: merged, soundCandidates: soundCandidates)
    }

    @discardableResult
    func replaceLocalMessageWithRemoteConfirmation(
        localID: String,
        remoteMessageID: String,
        remoteMapped: ChatMessage,
        remoteDisplayTime: String,
        remoteCreatedAt: Date?,
        remoteChannelSeq: Int64,
        in conversationID: String,
        readReceiptsEnabled: Bool
    ) -> ConfirmedLocalMessageReplacement? {
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == localID }) else { return nil }
        let previous = conversations[cIndex].messages[mIndex]
        let confirmed = confirmedLocalMessage(
            previous: previous,
            remoteMapped: remoteMapped,
            remoteMessageID: remoteMessageID,
            remoteDisplayTime: remoteDisplayTime,
            remoteCreatedAt: remoteCreatedAt,
            remoteChannelSeq: remoteChannelSeq,
            readReceiptsEnabled: readReceiptsEnabled
        )
        conversations[cIndex].messages[mIndex] = confirmed
        updateConversationLatestFromMessages(at: cIndex)
        return ConfirmedLocalMessageReplacement(previousMessage: previous, confirmedMessage: confirmed)
    }

    func confirmedLocalMessage(
        previous: ChatMessage,
        remoteMapped: ChatMessage,
        remoteMessageID: String,
        remoteDisplayTime: String,
        remoteCreatedAt: Date?,
        remoteChannelSeq: Int64,
        readReceiptsEnabled: Bool
    ) -> ChatMessage {
        let previousPreviewURL = retainedRemoteAttachmentURL(previous.attachmentPreviewURL)
        let previousDownloadURL = retainedRemoteAttachmentURL(previous.attachmentDownloadURL)
        let mergedPreviewURL = remoteMapped.attachmentPreviewURL.isEmpty ? previousPreviewURL : remoteMapped.attachmentPreviewURL
        let mergedDownloadURL = remoteMapped.attachmentDownloadURL.isEmpty ? previousDownloadURL : remoteMapped.attachmentDownloadURL
        var merged = ChatMessage(
            id: remoteMessageID,
            senderId: remoteMapped.senderProvenance == .authoritativeStored
                ? remoteMapped.senderId
                : previous.senderId,
            senderProvenance: remoteMapped.senderProvenance,
            senderName: previous.senderName,
            senderAvatarURL: remoteMapped.senderAvatarURL.isEmpty ? previous.senderAvatarURL : remoteMapped.senderAvatarURL,
            senderAvatarVersion: remoteMapped.senderAvatarVersion.isEmpty ? previous.senderAvatarVersion : remoteMapped.senderAvatarVersion,
            senderAvatarUpdatedAt: remoteMapped.senderAvatarUpdatedAt.isEmpty ? previous.senderAvatarUpdatedAt : remoteMapped.senderAvatarUpdatedAt,
            senderAvatarSeed: remoteMapped.senderAvatarSeed == 0 ? previous.senderAvatarSeed : remoteMapped.senderAvatarSeed,
            text: previous.text,
            time: remoteDisplayTime,
            createdAt: remoteCreatedAt ?? previous.createdAt,
            channelSeq: remoteChannelSeq,
            isOutgoing: previous.isOutgoing,
            status: previous.status == .read || (previous.readCount ?? 0) > 0 || !previous.readBy.isEmpty ? .read : .sent,
            kind: previous.kind,
            reactions: previous.reactions,
            reactionDetails: previous.reactionDetails,
            readBy: previous.readBy,
            unreadBy: previous.unreadBy,
            readCount: previous.readCount,
            readStateKnown: previous.readStateKnown,
            deliveryStateKnown: previous.deliveryStateKnown,
            canViewReadDetails: previous.canViewReadDetails,
            quote: remoteMapped.quote ?? previous.quote,
            attachmentName: previous.attachmentName,
            attachmentMeta: previous.attachmentMeta,
            attachmentFileID: remoteMapped.attachmentFileID?.isEmpty == false ? remoteMapped.attachmentFileID : previous.attachmentFileID,
            attachmentSizeBytes: previous.attachmentSizeBytes,
            attachmentPreviewURL: mergedPreviewURL,
            attachmentDownloadURL: mergedDownloadURL,
            attachmentPreviewAvailable: (!mergedPreviewURL.isEmpty && previous.attachmentPreviewAvailable) || remoteMapped.attachmentPreviewAvailable,
            attachmentDownloadAvailable: (!mergedDownloadURL.isEmpty && previous.attachmentDownloadAvailable) || remoteMapped.attachmentDownloadAvailable,
            attachmentTransferProgress: nil,
            isPinned: previous.isPinned,
            isFavorited: previous.isFavorited,
            isDeletedLocally: previous.isDeletedLocally,
            isEdited: previous.isEdited,
            auditTags: previous.auditTags,
            reportState: previous.reportState,
            serverTrace: remoteMessageID
        )
        merged.attachmentMediaCategory = remoteMapped.attachmentMediaCategory.isEmpty ? previous.attachmentMediaCategory : remoteMapped.attachmentMediaCategory
        merged.attachmentMimeType = remoteMapped.attachmentMimeType.isEmpty ? previous.attachmentMimeType : remoteMapped.attachmentMimeType
        merged.attachmentCacheKey = remoteMapped.attachmentCacheKey.isEmpty ? previous.attachmentCacheKey : remoteMapped.attachmentCacheKey
        merged.attachmentVersion = remoteMapped.attachmentVersion.isEmpty ? previous.attachmentVersion : remoteMapped.attachmentVersion
        merged.attachmentChecksum = remoteMapped.attachmentChecksum.isEmpty ? previous.attachmentChecksum : remoteMapped.attachmentChecksum
        merged.attachmentExtension = remoteMapped.attachmentExtension.isEmpty ? previous.attachmentExtension : remoteMapped.attachmentExtension
        merged.attachmentThumbnailURL = remoteMapped.attachmentThumbnailURL.isEmpty ? retainedRemoteAttachmentURL(previous.attachmentThumbnailURL) : remoteMapped.attachmentThumbnailURL
        merged.attachmentPosterURL = remoteMapped.attachmentPosterURL.isEmpty ? retainedRemoteAttachmentURL(previous.attachmentPosterURL) : remoteMapped.attachmentPosterURL
        merged.attachmentCoverURL = remoteMapped.attachmentCoverURL.isEmpty ? retainedRemoteAttachmentURL(previous.attachmentCoverURL) : remoteMapped.attachmentCoverURL
        merged.attachmentPreviewKind = remoteMapped.attachmentPreviewKind.isEmpty ? previous.attachmentPreviewKind : remoteMapped.attachmentPreviewKind
        merged.attachmentContentDisposition = remoteMapped.attachmentContentDisposition.isEmpty ? previous.attachmentContentDisposition : remoteMapped.attachmentContentDisposition
        merged.attachmentWidth = remoteMapped.attachmentWidth ?? previous.attachmentWidth
        merged.attachmentHeight = remoteMapped.attachmentHeight ?? previous.attachmentHeight
        merged.attachmentDurationSeconds = remoteMapped.attachmentDurationSeconds ?? previous.attachmentDurationSeconds
        merged.attachmentUploadStatus = normalizedCompletedAttachmentStatus(remoteMapped.attachmentUploadStatus)
        merged.attachmentUploadFailure = nil
        merged.replyContext = remoteMapped.replyContext ?? previous.replyContext
        merged.mentionExcluded = remoteMapped.mentionExcluded || previous.mentionExcluded
        merged.mentionAll = remoteMapped.mentionAll || previous.mentionAll
        merged.mentionedUsers = remoteMapped.mentionedUsers.isEmpty
            ? previous.mentionedUsers
            : remoteMapped.mentionedUsers
        if !readReceiptsEnabled {
            stripReadReceiptDetails(from: &merged)
        }
        return merged
    }

    // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_FAST_PATH - 修改开始：旧消息分页优先线性 prepend 合并，避免全量排序和大集合重建
    private func mergeOlderHistoryPrependIfPossible(
        previous: Conversation,
        mappedRemoteMessages: [MappedRemoteMessage],
        readReceiptsEnabled: Bool,
        windowRetention: MessageWindowRetention,
        sequenceCoverageAfterSeq: Int64?,
        olderHistoryBeforeSeq: Int64,
        coveredChannelSeqs: [Int64]?,
        effectiveReadSeq: Int64
    ) -> MergedRemoteMessagesResult? {
        guard olderHistoryBeforeSeq > 1,
              windowRetention == .preserveLoadedHistory,
              !mappedRemoteMessages.isEmpty,
              !previous.messages.isEmpty,
              messagesAreTimelineSorted(previous.messages),
              previous.lastMsgSeq > 0,
              previous.messageCoveredThroughSeq > 0 || previous.messageCoverageRequiresRecovery else {
            return nil
        }

        var incomingIDs = Set<String>()
        var incomingSeqs = Set<Int64>()
        var incomingEntries: [(entry: MappedRemoteMessage, message: ChatMessage)] = []
        incomingEntries.reserveCapacity(mappedRemoteMessages.count)

        for entry in mappedRemoteMessages {
            guard entry.matchedLocalID == nil else { return nil }
            let sequence = entry.remote.channelSeq
            guard sequence > 0, sequence < olderHistoryBeforeSeq else { return nil }
            // Fast prepend is only for ordinary history. A malformed RTC record
            // has no typed authority but still needs the normal conflict/gap path.
            // A declared call ID may also refer to an authority in another chat;
            // let the existing merge resolve it rather than duplicating validation.
            guard entry.message.rtcCallRecord == nil,
                  !entry.message.isRTCCallRecordMessage,
                  entry.message.kind != .rtcCallRecord,
                  entry.remote.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "rtc_call_record",
                  entry.remote.payload["content_type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "rtc_call_record",
                  (entry.remote.payload["call_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
                return nil
            }

            let remoteMessageID = entry.remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let messageID = entry.message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteMessageID.isEmpty || !messageID.isEmpty else { return nil }
            if (!remoteMessageID.isEmpty && incomingIDs.contains(remoteMessageID))
                || (!messageID.isEmpty && incomingIDs.contains(messageID))
                || incomingSeqs.contains(sequence) {
                continue
            }

            incomingEntries.append((entry: entry, message: entry.message))
            if !remoteMessageID.isEmpty {
                incomingIDs.insert(remoteMessageID)
            }
            if !messageID.isEmpty {
                incomingIDs.insert(messageID)
            }
            incomingSeqs.insert(sequence)
        }

        guard !incomingEntries.isEmpty else { return nil }

        var retainedPrevious: [ChatMessage] = []
        retainedPrevious.reserveCapacity(previous.messages.count)
        var duplicatePreviousByID: [String: ChatMessage] = [:]
        var duplicatePreviousBySeq: [Int64: ChatMessage] = [:]
        for existing in previous.messages {
            let existingID = existing.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDuplicate = (!existingID.isEmpty && incomingIDs.contains(existingID))
                || (existing.channelSeq > 0 && incomingSeqs.contains(existing.channelSeq))
            guard isDuplicate else {
                retainedPrevious.append(existing)
                continue
            }
            if existing.rtcCallRecord != nil || existing.isRTCCallRecordMessage {
                return nil
            }
            if !existingID.isEmpty {
                duplicatePreviousByID[existingID] = existing
            }
            if existing.channelSeq > 0 {
                duplicatePreviousBySeq[existing.channelSeq] = existing
            }
        }

        var incomingMessages: [ChatMessage] = []
        incomingMessages.reserveCapacity(incomingEntries.count)
        for item in incomingEntries {
            var message = item.message
            let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let previousMessage = (!messageID.isEmpty ? duplicatePreviousByID[messageID] : nil)
                ?? (message.channelSeq > 0 ? duplicatePreviousBySeq[message.channelSeq] : nil) {
                mergeExistingRemoteState(from: previousMessage, into: &message)
            }
            applyRemoteReadSummary(from: item.entry.remote, to: &message, readReceiptsEnabled: readReceiptsEnabled)
            incomingMessages.append(message)
        }

        incomingMessages.sort(by: messageTimelinePrecedes)
        let messages = mergedTimelineMessages(incomingMessages, retainedPrevious)
        let latestKnownSeq = max(previous.lastMsgSeq, incomingSeqs.max() ?? 0)
        var coveredThrough = max(previous.messageCoveredThroughSeq, sequenceCoverageAfterSeq ?? 0)
        let observedSequences = Set(
            (coveredChannelSeqs ?? mappedRemoteMessages.map { $0.remote.channelSeq })
                .filter { $0 > coveredThrough }
        ).sorted()
        for sequence in observedSequences {
            guard sequence == coveredThrough + 1 else { break }
            coveredThrough = sequence
        }
        let messageCoverageRequiresRecovery = previous.messageCoverageRequiresRecovery || latestKnownSeq > coveredThrough
        let sequenceRecoveryAfterSeq = messageCoverageRequiresRecovery ? coveredThrough : nil
        let sequenceRecoveryThroughSeq = sequenceRecoveryAfterSeq == nil ? nil : latestKnownSeq
        let latestMessage = latestConfirmedMessage(in: retainedPrevious)
            ?? latestConfirmedMessage(in: incomingMessages)
            ?? messages.last

        return MergedRemoteMessagesResult(
            messages: messages,
            latestMessage: latestMessage,
            incomingRealtimeMessages: [],
            latestKnownSeq: latestKnownSeq,
            messageCoveredThroughSeq: coveredThrough,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
            sequenceRecoveryAfterSeq: sequenceRecoveryAfterSeq,
            sequenceRecoveryThroughSeq: sequenceRecoveryThroughSeq,
            pendingLocalFinalizations: []
        )
    }

    private func mergedTimelineMessages(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> [ChatMessage] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        var merged: [ChatMessage] = []
        merged.reserveCapacity(lhs.count + rhs.count)
        var lhsIndex = 0
        var rhsIndex = 0
        while lhsIndex < lhs.count, rhsIndex < rhs.count {
            if messageTimelinePrecedes(lhs[lhsIndex], rhs[rhsIndex]) {
                merged.append(lhs[lhsIndex])
                lhsIndex += 1
            } else {
                merged.append(rhs[rhsIndex])
                rhsIndex += 1
            }
        }
        if lhsIndex < lhs.count {
            merged.append(contentsOf: lhs[lhsIndex...])
        }
        if rhsIndex < rhs.count {
            merged.append(contentsOf: rhs[rhsIndex...])
        }
        return merged
    }

    private func messagesAreTimelineSorted(_ messages: [ChatMessage]) -> Bool {
        guard messages.count > 1 else { return true }
        for index in messages.indices.dropFirst() {
            let previousIndex = messages.index(before: index)
            if messageTimelinePrecedes(messages[index], messages[previousIndex]) {
                return false
            }
        }
        return true
    }
    // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_FAST_PATH - 修改结束：旧消息分页优先线性 prepend 合并，避免全量排序和大集合重建

    func mergeMappedRemoteMessages(
        previous: Conversation?,
        mappedRemoteMessages: [MappedRemoteMessage],
        readReceiptsEnabled: Bool,
        fromRealtime: Bool,
        windowRetention: MessageWindowRetention = .preserveLoadedHistory,
        sequenceCoverageAfterSeq: Int64? = nil,
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_PARAM - 修改开始：更早消息分页 beforeSeq 触发保守快捷合并
        olderHistoryBeforeSeq: Int64? = nil,
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_PARAM - 修改结束：更早消息分页 beforeSeq 触发保守快捷合并
        coveredChannelSeqs: [Int64]? = nil,
        effectiveReadSeq: Int64 = 0
    ) -> MergedRemoteMessagesResult {
        // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_PREPEND_STORE_GATE - 修改开始：旧消息同步优先尝试线性合并
        if let olderHistoryBeforeSeq,
           !fromRealtime,
           let previous,
           let fastResult = mergeOlderHistoryPrependIfPossible(
            previous: previous,
            mappedRemoteMessages: mappedRemoteMessages,
            readReceiptsEnabled: readReceiptsEnabled,
            windowRetention: windowRetention,
            sequenceCoverageAfterSeq: sequenceCoverageAfterSeq,
            olderHistoryBeforeSeq: olderHistoryBeforeSeq,
            coveredChannelSeqs: coveredChannelSeqs,
            effectiveReadSeq: effectiveReadSeq
           ) {
            return fastResult
        }
        // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_PREPEND_STORE_GATE - 修改结束：旧消息同步优先尝试线性合并
        var previousRTCAuthorityByCallID: [String: RTCCallRecordMessageDeduplicator.Authority] = [:]
        var rtcAuthorityConflictingSequences = Set<Int64>()
        let previousMessages = (previous?.messages ?? []).filter { message in
            guard let authority = RTCCallRecordMessageDeduplicator.authority(for: message) else { return true }
            if let existing = previousRTCAuthorityByCallID[authority.callID] {
                if existing != authority, authority.channelSeq > 0 {
                    rtcAuthorityConflictingSequences.insert(authority.channelSeq)
                }
                return false
            }
            previousRTCAuthorityByCallID[authority.callID] = authority
            return true
        }
        var globalRTCAuthorityByCallID: [String: RTCCallRecordMessageDeduplicator.Authority] = [:]
        for conversation in conversations where conversation.id != previous?.id {
            for message in conversation.messages {
                guard let authority = RTCCallRecordMessageDeduplicator.authority(for: message),
                      globalRTCAuthorityByCallID[authority.callID] == nil else { continue }
                globalRTCAuthorityByCallID[authority.callID] = authority
            }
        }
        var previousMessageByID: [String: ChatMessage] = [:]
        var previousMessageBySeq: [Int64: ChatMessage] = [:]
        previousMessages.forEach { previousMessage in
            previousMessageByID[previousMessage.id] = previousMessage
            if previousMessage.channelSeq > 0 {
                previousMessageBySeq[previousMessage.channelSeq] = previousMessage
            }
        }
        let previousMessageIDs = Set(previousMessages.map(\.id))
        let previousMessageSeqs = Set(previousMessages.map(\.channelSeq).filter { $0 > 0 })
        let previousLocalClientIDs = Set(previousMessages.compactMap { message -> String? in
            guard isPendingLocalMessage(message) else { return nil }
            return message.id
        })
        var acceptedEntries: [(entry: MappedRemoteMessage, message: ChatMessage)] = []
        var remoteMessageIDs = Set<String>()
        var remoteMessageSeqs = Set<Int64>()
        var remoteClientMessageIDs = Set<String>()
        var acceptedRTCAuthorityByCallID = previousRTCAuthorityByCallID
        var acceptedRTCAuthorityByMessageID: [String: RTCCallRecordMessageDeduplicator.Authority] = [:]
        var acceptedRTCAuthorityBySequence: [Int64: RTCCallRecordMessageDeduplicator.Authority] = [:]
        for authority in previousRTCAuthorityByCallID.values {
            if !authority.messageID.isEmpty { acceptedRTCAuthorityByMessageID[authority.messageID] = authority }
            if authority.channelSeq > 0 { acceptedRTCAuthorityBySequence[authority.channelSeq] = authority }
        }
        var matchedPendingLocalIDs = Set<String>()
        var pendingLocalFinalizations: [PendingLocalMessageFinalization] = []
        var remoteIDsBySequence: [Int64: Set<String>] = [:]
        for entry in mappedRemoteMessages where entry.remote.channelSeq > 0 {
            let remoteID = entry.remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteID.isEmpty else { continue }
            remoteIDsBySequence[entry.remote.channelSeq, default: []].insert(remoteID)
        }
        var conflictingSequences = Set(
            remoteIDsBySequence.compactMap { sequence, identifiers in
                identifiers.count > 1 ? sequence : nil
            }
        )

        for entry in mappedRemoteMessages {
            let remoteMessageID = entry.remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let authority = RTCCallRecordMessageDeduplicator.authority(for: entry.message)
            // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：复用既有 remote 查找结果，避免重复历史回读再次认领其它 pending
            let previousRemoteMessage = previousMessageByID[remoteMessageID]
                ?? (entry.remote.channelSeq > 0 ? previousMessageBySeq[entry.remote.channelSeq] : nil)
            // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
            let acceptedRTCIdentity = acceptedRTCAuthorityByMessageID[remoteMessageID]
                ?? (entry.remote.channelSeq > 0 ? acceptedRTCAuthorityBySequence[entry.remote.channelSeq] : nil)
            if (previousRemoteMessage?.rtcCallRecord != nil || acceptedRTCIdentity != nil), authority == nil {
                if entry.remote.channelSeq > 0 { rtcAuthorityConflictingSequences.insert(entry.remote.channelSeq) }
                continue
            }
            if let existing = acceptedRTCIdentity, let authority, existing != authority {
                if entry.remote.channelSeq > 0 { rtcAuthorityConflictingSequences.insert(entry.remote.channelSeq) }
                continue
            }
            if let declaredCallID = entry.remote.payload["call_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !declaredCallID.isEmpty,
               authority == nil,
               (acceptedRTCAuthorityByCallID[declaredCallID] != nil || globalRTCAuthorityByCallID[declaredCallID] != nil) {
                if entry.remote.channelSeq > 0 { rtcAuthorityConflictingSequences.insert(entry.remote.channelSeq) }
                continue
            }
            if let authority {
                if globalRTCAuthorityByCallID[authority.callID] != nil {
                    if authority.channelSeq > 0 { rtcAuthorityConflictingSequences.insert(authority.channelSeq) }
                    continue
                }
                if let existing = acceptedRTCAuthorityByCallID[authority.callID] {
                    if existing != authority, authority.channelSeq > 0 {
                        rtcAuthorityConflictingSequences.insert(authority.channelSeq)
                    }
                    continue
                }
            }
            if !remoteMessageID.isEmpty, remoteMessageIDs.contains(remoteMessageID) {
                continue
            }
            if entry.remote.channelSeq > 0, remoteMessageSeqs.contains(entry.remote.channelSeq) {
                continue
            }
            var message = entry.message
            if let previousMessage = previousRemoteMessage {
                let authoritativeSnapshot = entry.remote.payload["sender_snapshot_name"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if authoritativeSnapshot.isEmpty {
                    message.senderName = previousMessage.senderName
                }
                mergeExistingRemoteState(from: previousMessage, into: &message)
            }
            applyRemoteReadSummary(from: entry.remote, to: &message, readReceiptsEnabled: readReceiptsEnabled)
            acceptedEntries.append((entry: entry, message: message))
            if let authority = RTCCallRecordMessageDeduplicator.authority(for: message) {
                acceptedRTCAuthorityByCallID[authority.callID] = authority
                if !authority.messageID.isEmpty { acceptedRTCAuthorityByMessageID[authority.messageID] = authority }
                if authority.channelSeq > 0 { acceptedRTCAuthorityBySequence[authority.channelSeq] = authority }
            }
            if let matchedLocalID = entry.matchedLocalID {
                // JHT_MOD_BEGIN FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改开始：已确认 remote 的重复历史回读只能幂等更新自身，不能触发其它 local 的上传终结
                let remoteAlreadyConfirmed = previousRemoteMessage.map { !isPendingLocalMessage($0) } ?? false
                guard !remoteAlreadyConfirmed || entry.clientMessageIDs.contains(matchedLocalID) else {
                    if !remoteMessageID.isEmpty {
                        remoteMessageIDs.insert(remoteMessageID)
                    }
                    if entry.remote.channelSeq > 0 {
                        remoteMessageSeqs.insert(entry.remote.channelSeq)
                    }
                    remoteClientMessageIDs.formUnion(entry.clientMessageIDs)
                    continue
                }
                // JHT_MOD_END FIXTURE_073_ATTACHMENT_IDENTITY_GUARD_20260915 - 修改结束
                matchedPendingLocalIDs.insert(matchedLocalID)
                pendingLocalFinalizations.append(PendingLocalMessageFinalization(localID: matchedLocalID, remoteMessage: message))
            }
            if !remoteMessageID.isEmpty {
                remoteMessageIDs.insert(remoteMessageID)
            }
            if entry.remote.channelSeq > 0 {
                remoteMessageSeqs.insert(entry.remote.channelSeq)
            }
            remoteClientMessageIDs.formUnion(entry.clientMessageIDs)
        }
        conflictingSequences.formUnion(rtcAuthorityConflictingSequences)

        let incomingRealtimeMessages: [ChatMessage] = fromRealtime
            ? acceptedEntries.compactMap { item in
                let entry = item.entry
                let message = item.message
                guard !entry.isRemoteFromCurrentUser,
                      !message.isOutgoing,
                      (message.channelSeq <= 0 || message.channelSeq > effectiveReadSeq),
                      !previousMessageIDs.contains(message.id),
                      (message.channelSeq <= 0 || !previousMessageSeqs.contains(message.channelSeq)),
                      entry.clientMessageIDs.allSatisfy({ !previousLocalClientIDs.contains($0) }) else { return nil }
                return message
            }
            : []

        var messages = previousMessages.filter { existing in
            !isPendingLocalMessage(existing)
                && !remoteMessageIDs.contains(existing.id)
                && (existing.channelSeq <= 0 || !remoteMessageSeqs.contains(existing.channelSeq))
        }
        messages.append(contentsOf: acceptedEntries.map(\.message))

        let pendingLocal = previousMessages.filter { message in
            isPendingLocalMessage(message)
                && !remoteClientMessageIDs.contains(message.id)
                && !matchedPendingLocalIDs.contains(message.id)
        }
        if !pendingLocal.isEmpty {
            var existingMessageIDs = Set(messages.map(\.id))
            var existingMessageSeqs = Set(messages.map(\.channelSeq).filter { $0 > 0 })
            for message in pendingLocal
                where !existingMessageIDs.contains(message.id)
                    && (message.channelSeq <= 0 || !existingMessageSeqs.contains(message.channelSeq)) {
                messages.append(message)
                existingMessageIDs.insert(message.id)
                if message.channelSeq > 0 {
                    existingMessageSeqs.insert(message.channelSeq)
                }
            }
        }
        messages.sort(by: messageTimelinePrecedes)

        let latestKnownSeq = max(
            previous?.lastMsgSeq ?? 0,
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免消息合并时多次 map().max() 临时数组
            ConversationSequenceInspector.maximumInt64(mappedRemoteMessages.lazy.map { $0.remote.channelSeq }) ?? 0,
            ConversationSequenceInspector.maximumInt64(acceptedEntries.lazy.map { $0.entry.remote.channelSeq }) ?? 0,
            ConversationSequenceInspector.maximumChannelSeq(in: messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        )
        var coveredThrough = max(
            previous.map { messageSequenceCoveredThrough(in: $0) } ?? 0,
            sequenceCoverageAfterSeq ?? 0
        )
        if let firstRTCConflict = rtcAuthorityConflictingSequences.filter({ $0 > 0 }).min() {
            coveredThrough = min(coveredThrough, max(0, firstRTCConflict - 1))
        }
        let observedSequences = Set(
            (coveredChannelSeqs ?? mappedRemoteMessages.map { $0.remote.channelSeq })
                .filter { $0 > coveredThrough }
        ).sorted()
        for sequence in observedSequences {
            if sequence <= coveredThrough {
                continue
            }
            guard sequence == coveredThrough + 1,
                  !conflictingSequences.contains(sequence) else {
                break
            }
            coveredThrough = sequence
        }
        let sequenceRecoveryAfterSeq = (!rtcAuthorityConflictingSequences.isEmpty || latestKnownSeq > coveredThrough)
            ? coveredThrough
            : nil
        let messageCoverageRequiresRecovery = sequenceRecoveryAfterSeq != nil
        let sequenceRecoveryThroughSeq = max(latestKnownSeq, rtcAuthorityConflictingSequences.max() ?? 0)
        messages = retainedMessages(messages, for: windowRetention)
        return MergedRemoteMessagesResult(
            messages: messages,
            latestMessage: latestConfirmedMessage(in: messages) ?? messages.last,
            incomingRealtimeMessages: incomingRealtimeMessages,
            latestKnownSeq: latestKnownSeq,
            messageCoveredThroughSeq: coveredThrough,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
            sequenceRecoveryAfterSeq: sequenceRecoveryAfterSeq,
            sequenceRecoveryThroughSeq: sequenceRecoveryAfterSeq == nil ? nil : sequenceRecoveryThroughSeq,
            pendingLocalFinalizations: pendingLocalFinalizations
        )
    }

    private func inferredMessageSequenceCoverage(_ messages: [ChatMessage]) -> Int64 {
        // JHT_MOD_BEGIN MESSAGE_SEQUENCE_COVERAGE_LINEAR_PERF_20260912 - 修改开始：保持覆盖语义不变，去掉大消息数组排序开销
        var sequences = Set<Int64>()
        var minimumSequence: Int64?
        for message in messages {
            guard message.channelSeq > 0,
                  !message.isPinnedContextOnly,
                  !isPendingLocalMessage(message) else { continue }
            sequences.insert(message.channelSeq)
            if let currentMinimum = minimumSequence {
                minimumSequence = min(currentMinimum, message.channelSeq)
            } else {
                minimumSequence = message.channelSeq
            }
        }
        guard var coveredThrough = minimumSequence else { return 0 }
        while sequences.contains(coveredThrough + 1) {
            coveredThrough += 1
        }
        // JHT_MOD_END MESSAGE_SEQUENCE_COVERAGE_LINEAR_PERF_20260912 - 修改结束
        return coveredThrough
    }

    @discardableResult
    func applyMergedRemoteMessagesConversation(
        channelID: String,
        kind: ConversationKind,
        previous: Conversation?,
        title: String,
        subtitle: String,
        participants: [IMUser],
        messages: [ChatMessage],
        latestMessage: ChatMessage,
        incomingRealtimeMessages: [ChatMessage],
        latestKnownSeq: Int64,
        messageCoveredThroughSeq: Int64 = 0,
        messageCoverageRequiresRecovery: Bool = false,
        fromRealtime: Bool,
        isActiveRealtimeConversation: Bool,
        canAutoReadActiveRealtimeConversation: Bool,
        memberCount: Int?,
        accentHex: UInt,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        effectiveReadSeq: Int64 = 0,
        historyBoundary: HistoryVisibilityBoundary? = nil
    ) -> AppliedRemoteMessagesConversationResult {
        let hasNewRealtimeActivity = fromRealtime && !incomingRealtimeMessages.isEmpty
        let latestMessageIsCoveredByRead = fromRealtime
            && latestMessage.channelSeq > 0
            && latestMessage.channelSeq <= effectiveReadSeq
        let candidateSortTimestamp = effectiveCreatedAt(for: latestMessage)?.timeIntervalSince1970 ?? 0
        let previousSortTimestamp = previous?.sortTimestamp ?? 0
        let latestDisplayTime = latestMessage.time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? previous?.time ?? ""
            : latestMessage.time
        let hasNewerTimestamp = candidateSortTimestamp > previousSortTimestamp + 0.5
        let hasNewerSequence = latestKnownSeq > (previous?.lastMsgSeq ?? 0)
        let shouldUseLatestSummary = !latestMessageIsCoveredByRead
            && (previous == nil || hasNewRealtimeActivity || hasNewerTimestamp || hasNewerSequence)
        let sortTimestamp: TimeInterval
        let resolvedTime: String
        if shouldUseLatestSummary {
            sortTimestamp = max(previousSortTimestamp, candidateSortTimestamp)
            resolvedTime = latestDisplayTime
        } else {
            sortTimestamp = previousSortTimestamp > 0 ? previousSortTimestamp : candidateSortTimestamp
            resolvedTime = previous?.time ?? latestDisplayTime
        }

        let shouldAutoRead = fromRealtime
            && isActiveRealtimeConversation
            && canAutoReadActiveRealtimeConversation
            && !incomingRealtimeMessages.isEmpty
            && kind != .system
        let previousReadCoversKnownMessages = effectiveReadSeq > 0
            && (previous?.lastMsgSeq ?? 0) > 0
            && (previous?.lastMsgSeq ?? 0) <= effectiveReadSeq
        let previousUnread = previousReadCoversKnownMessages ? 0 : previous?.unread ?? 0
        let nextUnread: Int
        if fromRealtime,
           !incomingRealtimeMessages.isEmpty,
           (!isActiveRealtimeConversation || !canAutoReadActiveRealtimeConversation) {
            nextUnread = previousUnread + incomingRealtimeMessages.count
        } else {
            nextUnread = previousUnread
        }
        let firstNewUnreadMessage = fromRealtime && previousUnread == 0 && nextUnread > 0
            ? incomingRealtimeMessages.first
            : nil
        let nextFirstUnreadSeq: Int64 = {
            guard nextUnread > 0 else { return 0 }
            if previousUnread > 0 {
                return previous?.firstUnreadSeq ?? 0
            }
            return firstNewUnreadMessage?.channelSeq ?? 0
        }()
        let nextFirstUnreadMessageID: String = {
            guard nextUnread > 0 else { return "" }
            if previousUnread > 0 {
                return previous?.firstUnreadMessageID ?? ""
            }
            return firstNewUnreadMessage?.id ?? ""
        }()
        let previousUnreadReactionCount = previousReadCoversKnownMessages ? 0 : previous?.unreadReactionCount ?? 0
        let previousHasUnreadReaction = previousReadCoversKnownMessages ? false : previous?.hasUnreadReaction == true
        let hasUnreadReaction = nextUnread > 0 && (previousHasUnreadReaction || previousUnreadReactionCount > 0)
        let resolvedMemberCount = kind == .group
            ? resolvedGroupMemberCount(incoming: memberCount, existing: previous?.memberCount ?? 0, participants: participants)
            : memberCount
        let resolvedHistoryBoundary = historyBoundary ?? self.historyBoundary(for: previous)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = kind == .direct && normalizedTitle.isEmpty
            ? previous?.title ?? title
            : title
        let resolvedParticipants = kind == .direct && participants.isEmpty
            ? previous?.participants ?? participants
            : participants
        let mapped = Conversation(
            id: kind == .system ? "system_notification" : (previous?.id ?? channelID),
            title: resolvedTitle,
            subtitle: subtitle,
            kind: kind,
            lastMessage: shouldUseLatestSummary ? messageListPreview(latestMessage) : previous?.lastMessage ?? "",
            time: resolvedTime,
            unread: nextUnread,
            isPinned: previous?.isPinned ?? false,
            isMuted: previous?.isMuted ?? false,
            memberCount: resolvedMemberCount,
            accentHex: previous?.accentHex ?? accentHex,
            participants: resolvedParticipants,
            messages: messages,
            avatarURL: avatarURL.isEmpty ? previous?.avatarURL ?? "" : avatarURL,
            avatarVersion: avatarVersion.isEmpty ? previous?.avatarVersion ?? "" : avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt.isEmpty ? previous?.avatarUpdatedAt ?? "" : avatarUpdatedAt,
            hasUnreadReaction: hasUnreadReaction,
            unreadReactionCount: hasUnreadReaction ? previousUnreadReactionCount : 0,
            lastMsgSeq: latestKnownSeq,
            messageCoveredThroughSeq: messageCoveredThroughSeq,
            messageCoverageRequiresRecovery: messageCoverageRequiresRecovery,
            lastReadSeq: max(previous?.lastReadSeq ?? 0, effectiveReadSeq),
            firstUnreadSeq: nextFirstUnreadSeq,
            firstUnreadMessageID: nextFirstUnreadMessageID,
            unreadAnchorSeq: nextUnread > 0 ? (previousUnread > 0 ? previous?.unreadAnchorSeq ?? 0 : nextFirstUnreadSeq) : 0,
            unreadAnchorState: nextUnread > 0 ? (previousUnread > 0 ? previous?.unreadAnchorState ?? "unread" : "unread") : "none",
            hasMention: previous?.hasMention ?? false,
            mentionCount: previous?.mentionCount ?? 0,
            mentionSummaryText: previous?.mentionSummaryText ?? "",
            mentionSummaryMessageID: previous?.mentionSummaryMessageID ?? "",
            mentionSummaryChannelSeq: previous?.mentionSummaryChannelSeq ?? 0,
            sortTimestamp: sortTimestamp,
            historyVisibleFromSeq: resolvedHistoryBoundary?.fromSeq ?? previous?.historyVisibleFromSeq ?? 1,
            historyLimited: resolvedHistoryBoundary?.limited ?? previous?.historyLimited ?? false,
            historyBoundaryConfirmed: resolvedHistoryBoundary?.confirmed ?? previous?.historyBoundaryConfirmed ?? false
        )

        var next = conversations
        if let previous, let existingIndex = next.firstIndex(where: { $0.id == previous.id }) {
            next[existingIndex] = mapped
        } else if let existingIndex = next.firstIndex(where: { $0.id == mapped.id || $0.id == channelID }) {
            next[existingIndex] = mapped
        } else {
            next.insert(mapped, at: 0)
        }
        publishConversationsIfChanged(next.sorted(by: conversationListPrecedes))

        return AppliedRemoteMessagesConversationResult(
            conversation: mapped,
            incomingRealtimeMessages: incomingRealtimeMessages,
            shouldPlayIncomingSound: hasNewRealtimeActivity && !isActiveRealtimeConversation && !mapped.isMuted,
            shouldAutoRead: shouldAutoRead
        )
    }

    func recentHistoryAfterSeq(for conversation: Conversation, limit: Int) -> Int64 {
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：最近历史游标计算避免生成序号临时数组
        let localMaxSeq = ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        let latestKnownSeq = max(conversation.lastMsgSeq, localMaxSeq)
        guard latestKnownSeq > 0 else { return 0 }
        return max(0, latestKnownSeq - Int64(limit))
    }

    func initialMessageSyncWindows(for conversation: Conversation, limit: Int) -> [MessageSyncWindow] {
        let boundedLimit = max(limit, 1)
        let latestWindow = MessageSyncWindow(
            afterSeq: recentHistoryAfterSeq(for: conversation, limit: boundedLimit),
            limit: boundedLimit
        )
        return [latestWindow]
    }

    func messageSyncPlan(
        for conversation: Conversation,
        historyKey: String,
        force: Bool,
        latestHistoryWindowLimit: Int
    ) -> MessageSyncPlan {
        if !force, hasUsableRemoteHistory(for: conversation) {
            return .sidecarsOnly
        }
        return .remoteHistory(
            historyKey: historyKey,
            windows: initialMessageSyncWindows(for: conversation, limit: latestHistoryWindowLimit)
        )
    }

    func oldestConfirmedMessageSeq(in conversation: Conversation) -> Int64? {
        let confirmedMessages = conversation.messages
            .filter { message in
                message.channelSeq > 0
                    && !message.id.hasPrefix("local_")
                    && message.status != .sending
                    && message.status != .failed
        }
        guard !confirmedMessages.isEmpty else { return nil }
        // Pinned messages can be older highlights, not the normal timeline boundary.
        let timelineMessages = confirmedMessages.filter { !$0.isPinned }
        return (timelineMessages.isEmpty ? confirmedMessages : timelineMessages)
            .map(\.channelSeq)
            .min()
    }

    func olderHistoryAvailabilityPlan(for conversation: Conversation, historyKey: String) -> OlderHistoryAvailabilityPlan {
        let target = OlderHistoryAvailabilityTarget(
            historyKey: historyKey,
            conversationID: conversation.id,
            oldestSeq: oldestConfirmedMessageSeq(in: conversation) ?? 0
        )
        guard !hasReachedHistoryStart(historyKey: target.historyKey) else {
            return .reachedStart(historyKey: target.historyKey, conversationID: target.conversationID)
        }
        if let boundary = historyBoundary(for: conversation),
           boundary.isRestrictive,
           target.oldestSeq > 0,
           target.oldestSeq <= boundary.fromSeq {
            return .reachedStart(historyKey: target.historyKey, conversationID: target.conversationID)
        }
        guard target.oldestSeq > 1 else {
            return .unavailable(historyKey: target.historyKey, conversationID: target.conversationID)
        }
        return .available(target)
    }

    func olderHistoryAvailabilityTarget(for conversation: Conversation, historyKey: String) -> OlderHistoryAvailabilityTarget? {
        guard case .available(let target) = olderHistoryAvailabilityPlan(for: conversation, historyKey: historyKey) else {
            return nil
        }
        return target
    }

    func newestConfirmedMessageSeq(in conversation: Conversation) -> Int64? {
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：单次扫描可用远端消息，避免 filter + map 双重临时数组
        var newestSeq: Int64?
        for message in conversation.messages
            where message.channelSeq > 0
                && !message.isPinnedContextOnly
                && isUsableRemoteHistoryMessage(message) {
            if let current = newestSeq {
                if message.channelSeq > current {
                    newestSeq = message.channelSeq
                }
            } else {
                newestSeq = message.channelSeq
            }
        }
        return newestSeq
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
    }

    func newerHistoryAvailabilityTarget(
        for conversation: Conversation,
        historyKey: String,
        limit: Int
    ) -> NewerHistoryAvailabilityTarget? {
        guard let newestSeq = newestConfirmedMessageSeq(in: conversation), newestSeq > 0 else { return nil }
        let latestKnownSeq = max(conversation.lastMsgSeq, newestSeq)
        guard latestKnownSeq > newestSeq else { return nil }
        return NewerHistoryAvailabilityTarget(
            historyKey: historyKey,
            conversationID: conversation.id,
            afterSeq: newestSeq,
            latestKnownSeq: latestKnownSeq,
            limit: limit
        )
    }

    func hasUsableRemoteHistory(for conversation: Conversation) -> Bool {
        let confirmedMessages = conversation.messages.filter(isUsableRemoteHistoryMessage)
        guard !confirmedMessages.isEmpty else { return false }
        guard confirmedMessages.count > 1 else { return false }
        let sequencedMessages = confirmedMessages.filter { $0.channelSeq > 0 }
        if conversation.lastMsgSeq > 0 {
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免历史可用性检查生成序号临时数组
            let latestLocalSeq = ConversationSequenceInspector.maximumChannelSeq(in: sequencedMessages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            guard latestLocalSeq >= conversation.lastMsgSeq else { return false }
            let expectedRecentCount = Int(min(Int64(20), max(Int64(1), conversation.lastMsgSeq)))
            let lowerBound = max(Int64(0), conversation.lastMsgSeq - Int64(expectedRecentCount))
            let recentConfirmedIDs = Set(sequencedMessages.filter { $0.channelSeq > lowerBound }.map(\.id))
            guard recentConfirmedIDs.count >= expectedRecentCount else { return false }
        }
        if conversation.kind != .system,
           conversation.lastMsgSeq > 1,
           confirmedMessages.filter({ !$0.isPinned }).count <= 1 {
            return false
        }
        guard conversation.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return true
        }
        return confirmedMessages.contains { message in
            message.text == conversation.lastMessage || message.channelSeq > 0
        }
    }

    @discardableResult
    func trimConversationToLatestWindow(conversationID: String, limit: Int) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        let currentMessages = conversations[index].messages
        let retained = retainedMessages(currentMessages, for: .latestTail(limit: limit))
        guard retained.map(\.id) != currentMessages.map(\.id) else { return false }
        conversations[index].messages = retained
        return true
    }

    func needsHistoryHydration(
        local: Conversation?,
        remoteLatestSeq: Int64,
        remoteLastMessageID: String?
    ) -> Bool {
        guard let local else { return true }
        guard !local.messages.isEmpty else { return true }
        guard local.messages.count > 1 else { return true }
        if remoteLatestSeq > 0 {
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免历史补水判断生成序号临时数组
            let localLatestMessageSeq = ConversationSequenceInspector.maximumChannelSeq(in: local.messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            if remoteLatestSeq > localLatestMessageSeq {
                return true
            }
        }
        let normalizedLastMessageID = remoteLastMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedLastMessageID.isEmpty,
           !local.messages.contains(where: { $0.id == normalizedLastMessageID }) {
            return true
        }
        return !hasUsableRemoteHistory(for: local)
    }

    func historyPrefetchTargets(
        candidates: [HistoryPrefetchCandidate],
        limit: Int
    ) -> [HistoryPrefetchTarget] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        return candidates
            .filter { candidate in
                needsHistoryHydration(
                    local: candidate.local,
                    remoteLatestSeq: candidate.latestSeq,
                    remoteLastMessageID: candidate.remote.lastMessage?.messageID
                )
            }
            .sorted(by: historyPrefetchCandidatePrecedes)
            .prefix(boundedLimit)
            .map { candidate in
                HistoryPrefetchTarget(
                    remote: candidate.remote,
                    channelID: candidate.channelID,
                    reason: historyPrefetchReason(for: candidate),
                    latestSeq: candidate.latestSeq,
                    sortTimestamp: candidate.sortTimestamp,
                    logID: candidate.logID
                )
            }
    }

    func historyPrefetchExecutionPlan(
        targets: [HistoryPrefetchTarget],
        messageLimit: Int,
        maxConcurrent: Int
    ) -> HistoryPrefetchExecutionPlan {
        let boundedMessageLimit = max(1, messageLimit)
        let boundedMaxConcurrent = max(1, maxConcurrent)
        let commands = targets.map { target in
            let afterSeq = target.remote.lastMsgSeq > Int64(boundedMessageLimit)
                ? target.remote.lastMsgSeq - Int64(boundedMessageLimit)
                : 0
            return HistoryPrefetchFetchCommand(
                remote: target.remote,
                channelID: target.channelID,
                apiChannelID: target.remote.channelID,
                channelType: target.remote.channelType,
                afterSeq: afterSeq,
                limit: boundedMessageLimit,
                reason: target.reason,
                summaryFragment: target.summaryFragment
            )
        }
        return HistoryPrefetchExecutionPlan(
            commands: commands,
            maxConcurrent: boundedMaxConcurrent
        )
    }

    func historyPrefetchReadReceiptBackfillTarget(
        for command: HistoryPrefetchFetchCommand,
        readReceiptsEnabled: Bool,
        channelIDForConversation: (Conversation) -> String
    ) -> HistoryPrefetchReadReceiptBackfillTarget? {
        // Delivery receipts are a baseline transport capability, so sidecar
        // catch-up remains active even when detailed read receipts are licensed off.
        _ = readReceiptsEnabled
        let lookupID = command.apiChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookupID.isEmpty else { return nil }
        let hasOutgoingMessages = conversations
            .first { conversation in
                conversation.id == lookupID || channelIDForConversation(conversation) == lookupID
            }?
            .messages
            .contains { $0.isOutgoing } == true
        guard hasOutgoingMessages else { return nil }
        return HistoryPrefetchReadReceiptBackfillTarget(
            channelID: command.apiChannelID,
            channelType: command.channelType
        )
    }

    private func historyPrefetchCandidatePrecedes(_ lhs: HistoryPrefetchCandidate, _ rhs: HistoryPrefetchCandidate) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
        if lhs.remote.unreadCount != rhs.remote.unreadCount { return lhs.remote.unreadCount > rhs.remote.unreadCount }
        if lhs.sortTimestamp != rhs.sortTimestamp { return lhs.sortTimestamp > rhs.sortTimestamp }
        if lhs.latestSeq != rhs.latestSeq { return lhs.latestSeq > rhs.latestSeq }
        if lhs.remote.stick != rhs.remote.stick { return lhs.remote.stick && !rhs.remote.stick }
        return lhs.channelID < rhs.channelID
    }

    private func historyPrefetchReason(for candidate: HistoryPrefetchCandidate) -> String {
        if candidate.isActive { return "active" }
        if candidate.remote.unreadCount > 0 { return "unread" }
        // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免预取原因判断生成序号临时数组
        let localLatestSeq = candidate.local.map {
            ConversationSequenceInspector.maximumChannelSeq(in: $0.messages) ?? 0
        } ?? 0
        // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        if candidate.latestSeq > localLatestSeq { return "latest_seq" }
        return "recent_activity"
    }

    func isRemoteMessageOlderThanCurrentWindow(
        _ remote: RemoteMessage,
        oldestSeq: Int64,
        existingIDs: Set<String>,
        existingSeqs: Set<Int64>
    ) -> Bool {
        remote.channelSeq > 0
            && remote.channelSeq < oldestSeq
            && !existingIDs.contains(remote.messageID)
            && !existingSeqs.contains(remote.channelSeq)
    }

    func isRemoteMessageNewerThanCurrentWindow(
        _ remote: RemoteMessage,
        newestSeq: Int64,
        existingIDs: Set<String>,
        existingSeqs: Set<Int64>
    ) -> Bool {
        remote.channelSeq > 0
            && remote.channelSeq > newestSeq
            && !existingIDs.contains(remote.messageID)
            && !existingSeqs.contains(remote.channelSeq)
    }

    private func isUsableRemoteHistoryMessage(_ message: ChatMessage) -> Bool {
        !message.id.hasPrefix("local_")
            && message.status != .sending
            && message.status != .failed
            && message.status != .recalled
            && !message.isDeletedLocally
    }

    private func retainedMessages(_ messages: [ChatMessage], for retention: MessageWindowRetention) -> [ChatMessage] {
        guard case .latestTail(let limit) = retention else { return messages }
        let boundedLimit = max(1, limit)
        let timelineMessages = messages.filter { message in
            !message.isPinnedContextOnly && !isPendingLocalMessage(message)
        }
        guard timelineMessages.count > boundedLimit else { return messages }
        let tailIDs = Set(timelineMessages.suffix(boundedLimit).map(\.id))
        var retained = messages.filter { message in
            tailIDs.contains(message.id)
                || isPendingLocalMessage(message)
                || message.isPinnedContextOnly
        }
        retained.sort(by: messageTimelinePrecedes)
        return retained
    }

    func clearUnread(conversationID: String, includeSystemConversations: Bool) {
        for index in conversations.indices where conversations[index].id == conversationID || (includeSystemConversations && conversations[index].kind == .system) {
            conversations[index].lastReadSeq = max(conversations[index].lastReadSeq, latestReadableSequence(in: conversations[index]))
            conversations[index].unread = 0
            conversations[index].hasUnreadReaction = false
            conversations[index].unreadReactionCount = 0
            conversations[index].firstUnreadSeq = 0
            conversations[index].firstUnreadMessageID = ""
            conversations[index].unreadAnchorSeq = 0
            conversations[index].unreadAnchorState = "none"
        }
    }

    func clearUnread(conversationID: String, isSystemConversationID: (String) -> Bool) {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let targetIsSystem = conversations.first(where: { $0.id == key })?.kind == .system
            || isSystemConversationID(key)
        clearUnread(conversationID: key, includeSystemConversations: targetIsSystem)
    }

    func advanceRead(conversationID: String, through confirmedSeq: Int64) {
        guard confirmedSeq > 0,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let latestSeq = latestReadableSequence(in: conversations[index])
        let boundedSeq = min(confirmedSeq, latestSeq)
        let previousReadSeq = conversations[index].lastReadSeq
        guard boundedSeq > previousReadSeq else { return }

        conversations[index].lastReadSeq = boundedSeq
        // The readable prefix may stop at a coverage gap before the known tail.
        let knownTailSeq = max(
            conversations[index].lastMsgSeq,
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免已读推进时生成序号临时数组
            ConversationSequenceInspector.maximumChannelSeq(in: conversations[index].messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
        )
        guard boundedSeq < max(latestSeq, knownTailSeq) else {
            clearUnread(conversationID: conversationID, includeSystemConversations: false)
            return
        }

        let previousUnread = conversations[index].unread
        let acknowledgedIncomingCount = conversations[index].messages.filter { message in
            !message.isOutgoing
                && message.channelSeq > previousReadSeq
                && message.channelSeq <= boundedSeq
        }.count
        let remainingIncoming = conversations[index].messages
            .filter { !$0.isOutgoing && $0.channelSeq > boundedSeq }
            .sorted { $0.channelSeq < $1.channelSeq }
        let unresolvedReactionMinimum = conversations[index].hasUnreadReaction
            || conversations[index].unreadReactionCount > 0
            ? max(1, conversations[index].unreadReactionCount)
            : 0
        conversations[index].unread = max(
            unresolvedReactionMinimum,
            max(remainingIncoming.count, max(0, previousUnread - acknowledgedIncomingCount))
        )
        if let firstUnread = remainingIncoming.first {
            if conversations[index].firstUnreadSeq <= boundedSeq
                || conversations[index].firstUnreadSeq >= firstUnread.channelSeq {
                conversations[index].firstUnreadSeq = firstUnread.channelSeq
                conversations[index].firstUnreadMessageID = firstUnread.id
            }
            if conversations[index].unreadAnchorSeq <= boundedSeq {
                conversations[index].unreadAnchorSeq = conversations[index].firstUnreadSeq
            }
        } else if conversations[index].firstUnreadSeq <= boundedSeq {
            conversations[index].firstUnreadSeq = 0
            conversations[index].firstUnreadMessageID = ""
            if conversations[index].unreadAnchorSeq <= boundedSeq {
                conversations[index].unreadAnchorSeq = 0
            }
        }
        if conversations[index].unread == 0 {
            conversations[index].unreadAnchorState = "none"
        }
    }

    func replaceSystemConversation(_ buildConversation: (Conversation?) -> Conversation?) {
        let previousSystem = conversations.first(where: { $0.kind == .system && $0.id == "system_notification" })
            ?? conversations.first(where: { $0.kind == .system })
        conversations.removeAll { $0.kind == .system }
        guard let conversation = buildConversation(previousSystem) else { return }
        conversations.insert(conversation, at: 0)
    }

    func removeDirectConversations(
        peerID: String,
        directPeerID: (Conversation) -> String?
    ) {
        let normalizedID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        conversations.removeAll { conversation in
            guard conversation.kind == .direct else { return false }
            if directPeerID(conversation) == normalizedID { return true }
            if conversation.participants.contains(where: { $0.id == normalizedID }) { return true }
            return conversation.id
                .split(separator: ":")
                .map(String.init)
                .contains(normalizedID)
        }
    }

    func rememberRead(key: String, readSeq: Int64) {
        guard !key.isEmpty, readSeq > 0 else { return }
        locallyReadSeqs[key] = max(locallyReadSeqs[key] ?? 0, readSeq)
        if let pendingSeq = pendingReadAckSeqs[key], pendingSeq <= (locallyReadSeqs[key] ?? 0) {
            pendingReadAckSeqs.removeValue(forKey: key)
        }
    }

    @discardableResult
    func rememberReadWatermark(_ watermark: ReadWatermark) -> Int64 {
        let key = watermark.scope.storageKey
        let nextSeq = max(scopedReadWatermarkSeqs[key] ?? 0, watermark.lastReadSeq)
        scopedReadWatermarkSeqs[key] = nextSeq
        return nextSeq
    }

    func locallyReadSeq(forKey key: String) -> Int64 {
        locallyReadSeqs[key] ?? 0
    }

    func scopedReadWatermarkSeq(for scope: ReadWatermarkScope?) -> Int64 {
        guard let scope else { return 0 }
        return scopedReadWatermarkSeqs[scope.storageKey] ?? 0
    }

    func effectiveReadSeq(readStateKey: String, scope: ReadWatermarkScope?) -> Int64 {
        guard let scope else { return locallyReadSeq(forKey: readStateKey) }
        return scopedReadWatermarkSeq(for: scope)
    }

    func isReadByEffectiveWatermark(channelSeq: Int64, readStateKey: String, scope: ReadWatermarkScope?) -> Bool {
        guard channelSeq > 0 else { return false }
        return channelSeq <= effectiveReadSeq(readStateKey: readStateKey, scope: scope)
    }

    func hasLocallyReadSeqs() -> Bool {
        !locallyReadSeqs.isEmpty || !scopedReadWatermarkSeqs.isEmpty
    }

    func rememberedConversationBottomSeq(stateKey: String) -> Int64 {
        confirmedConversationBottomSeqByScope[stateKey.trimmingCharacters(in: .whitespacesAndNewlines)] ?? 0
    }

    func rememberConversationBottomSeq(_ seq: Int64, stateKey: String) {
        guard seq > 0 else { return }
        let key = stateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        confirmedConversationBottomSeqByScope[key] = max(seq, confirmedConversationBottomSeqByScope[key] ?? 0)
    }

    func hasConfirmedConversationBottomSeqs() -> Bool {
        !confirmedConversationBottomSeqByScope.isEmpty
    }

    func prepareActiveRealtimeConversationAutoRead(conversationID: String) {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        activeRealtimeConversationAutoReadEnabled[key] = false
    }

    @discardableResult
    func updateActiveRealtimeConversationAutoRead(
        conversationID: String,
        activeConversationID: String?,
        canAutoRead: Bool
    ) -> Bool {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = (activeConversationID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key == activeKey else { return false }
        activeRealtimeConversationAutoReadEnabled[key] = canAutoRead
        return true
    }

    func clearActiveRealtimeConversationAutoRead(conversationID: String) {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        activeRealtimeConversationAutoReadEnabled.removeValue(forKey: key)
    }

    func activeRealtimeConversationAutoReadState(conversationID: String) -> Bool? {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return activeRealtimeConversationAutoReadEnabled[key]
    }

    func hasActiveRealtimeConversationAutoReadStates() -> Bool {
        !activeRealtimeConversationAutoReadEnabled.isEmpty
    }

    func canAutoReadActiveRealtimeConversation(previousConversationID: String?, channelID: String) -> Bool {
        let channelKey = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousKey = (previousConversationID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryKey = previousKey.isEmpty ? channelKey : previousKey
        return activeRealtimeConversationAutoReadEnabled[primaryKey] == true
            || activeRealtimeConversationAutoReadEnabled[channelKey] == true
    }

    func replaceWarmRefreshTask(refreshKey: String, task: Task<Void, Never>) {
        let key = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            task.cancel()
            return
        }
        warmRefreshTasks[key]?.cancel()
        warmRefreshTasks[key] = task
    }

    func finishWarmRefreshTask(refreshKey: String) {
        let key = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        warmRefreshTasks.removeValue(forKey: key)
    }

    func hasWarmRefreshTask(refreshKey: String) -> Bool {
        let key = refreshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return warmRefreshTasks[key] != nil
    }

    func hasWarmRefreshTasks() -> Bool {
        !warmRefreshTasks.isEmpty
    }

    func cancelWarmRefreshTasks(conversationID: String) {
        let conversationKey = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationKey.isEmpty else { return }
        let suffix = "|\(conversationKey)"
        let keys = warmRefreshTasks.keys.filter { $0.hasSuffix(suffix) }
        for key in keys {
            warmRefreshTasks[key]?.cancel()
            warmRefreshTasks.removeValue(forKey: key)
        }
    }

    func cancelAllWarmRefreshTasks() {
        warmRefreshTasks.values.forEach { $0.cancel() }
        warmRefreshTasks.removeAll()
    }

    func shouldApplyReactionExtra(_ extra: RemoteMessageExtra) -> Bool {
        let key = extra.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return true }
        guard !appliedReactionExtraKeys.contains(key) else { return false }
        appliedReactionExtraKeys.insert(key)
        return true
    }

    @discardableResult
    func applyDedupedReactionExtraIfMissing(
        _ extra: RemoteMessageExtra,
        currentUserIDs: Set<String>,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> Bool {
        let normalizedEmoji = extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAction = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !extra.messageID.isEmpty,
              !normalizedEmoji.isEmpty else { return false }
        for cIndex in conversations.indices {
            guard let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }) else { continue }
            let detailID = reactionDetailID(
                messageID: extra.messageID,
                operatorUID: extra.operatorUID,
                emoji: normalizedEmoji
            )
            let isMine = currentUserIDs.contains(extra.operatorUID)
            let reactionIndex = conversations[cIndex].messages[mIndex].reactions.firstIndex {
                $0.emoji == normalizedEmoji
            }
            let hasOperatorDetail = conversations[cIndex].messages[mIndex].reactionDetails.contains {
                $0.id == detailID
            }
            if normalizedAction == "remove" {
                let hasOwnReaction = reactionIndex.map {
                    conversations[cIndex].messages[mIndex].reactions[$0].reactedByMe
                } ?? false
                guard hasOperatorDetail || (isMine && hasOwnReaction) else { return false }
                if let reactionIndex {
                    if hasOperatorDetail || (isMine && hasOwnReaction) {
                        conversations[cIndex].messages[mIndex].reactions[reactionIndex].count = max(
                            0,
                            conversations[cIndex].messages[mIndex].reactions[reactionIndex].count - 1
                        )
                    }
                    if isMine {
                        conversations[cIndex].messages[mIndex].reactions[reactionIndex].reactedByMe = false
                    }
                    if conversations[cIndex].messages[mIndex].reactions[reactionIndex].count == 0 {
                        conversations[cIndex].messages[mIndex].reactions.remove(at: reactionIndex)
                    }
                }
                conversations[cIndex].messages[mIndex].reactionDetails.removeAll { $0.id == detailID }
                return true
            }
            var didChange = false
            if let reactionIndex {
                if isMine, !conversations[cIndex].messages[mIndex].reactions[reactionIndex].reactedByMe {
                    conversations[cIndex].messages[mIndex].reactions[reactionIndex].reactedByMe = true
                    didChange = true
                }
            } else {
                conversations[cIndex].messages[mIndex].reactions.append(
                    Reaction(id: "\(extra.messageID)_\(normalizedEmoji)", emoji: normalizedEmoji, count: 1, reactedByMe: isMine)
                )
                didChange = true
            }
            if !hasOperatorDetail {
                conversations[cIndex].messages[mIndex].reactionDetails.append(makeReactionDetail(extra, detailID))
                didChange = true
            }
            return didChange
        }
        return false
    }

    // JHT_MOD_BEGIN MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改开始：同步回来的 reaction extras 批量应用，避免每条 extra 多次全表扫描和多次发布
    struct SyncedReactionExtrasApplyResult {
        let processed: Int
        let changed: Int
        let conversationsChanged: Int
        let messagesChanged: Int
        let skipped: [RemoteMessageExtra]

        static let empty = SyncedReactionExtrasApplyResult(
            processed: 0,
            changed: 0,
            conversationsChanged: 0,
            messagesChanged: 0,
            skipped: []
        )
    }

    @discardableResult
    func applySyncedReactionExtras(
        _ extras: [RemoteMessageExtra],
        currentUserIDs: Set<String>,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> SyncedReactionExtrasApplyResult {
        guard !extras.isEmpty else { return .empty }
        var reactionExtras: [(extra: RemoteMessageExtra, isDuplicate: Bool)] = []
        var skipped: [RemoteMessageExtra] = []
        reactionExtras.reserveCapacity(extras.count)
        for extra in extras {
            guard extra.isReaction else {
                skipped.append(extra)
                continue
            }
            let key = extra.dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || !appliedReactionExtraKeys.contains(key) {
                if !key.isEmpty {
                    appliedReactionExtraKeys.insert(key)
                }
                reactionExtras.append((extra, false))
            } else {
                reactionExtras.append((extra, true))
            }
        }
        guard !reactionExtras.isEmpty else {
            return SyncedReactionExtrasApplyResult(
                processed: 0,
                changed: 0,
                conversationsChanged: 0,
                messagesChanged: 0,
                skipped: skipped
            )
        }

        var extrasByMessageID: [String: [(extra: RemoteMessageExtra, isDuplicate: Bool)]] = [:]
        for item in reactionExtras {
            let messageID = item.extra.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = item.extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageID.isEmpty, !emoji.isEmpty else {
                skipped.append(item.extra)
                continue
            }
            extrasByMessageID[messageID, default: []].append(item)
        }
        guard !extrasByMessageID.isEmpty else {
            return SyncedReactionExtrasApplyResult(
                processed: reactionExtras.count,
                changed: 0,
                conversationsChanged: 0,
                messagesChanged: 0,
                skipped: skipped
            )
        }

        var updatedConversations = conversations
        var changedExtras = 0
        var conversationsChanged = 0
        var messagesChanged = 0

        for cIndex in updatedConversations.indices {
            var conversation = updatedConversations[cIndex]
            var conversationDidChange = false
            for mIndex in conversation.messages.indices {
                let messageID = conversation.messages[mIndex].id
                guard let messageExtras = extrasByMessageID[messageID] else { continue }
                var message = conversation.messages[mIndex]
                var messageDidChange = false
                for item in messageExtras {
                    if applySyncedReactionExtra(
                        item.extra,
                        to: &message,
                        isDuplicate: item.isDuplicate,
                        currentUserIDs: currentUserIDs,
                        makeReactionDetail: makeReactionDetail
                    ) {
                        changedExtras += 1
                        messageDidChange = true
                    }
                }
                guard messageDidChange else { continue }
                conversation.messages[mIndex] = message
                conversationDidChange = true
                messagesChanged += 1
            }
            guard conversationDidChange else { continue }
            updatedConversations[cIndex] = conversation
            conversationsChanged += 1
        }

        if conversationsChanged > 0 {
            conversations = updatedConversations
        }
        return SyncedReactionExtrasApplyResult(
            processed: reactionExtras.count,
            changed: changedExtras,
            conversationsChanged: conversationsChanged,
            messagesChanged: messagesChanged,
            skipped: skipped
        )
    }

    private func applySyncedReactionExtra(
        _ extra: RemoteMessageExtra,
        to message: inout ChatMessage,
        isDuplicate: Bool,
        currentUserIDs: Set<String>,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> Bool {
        let normalizedEmoji = extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.messageID.isEmpty, !normalizedEmoji.isEmpty else { return false }
        let normalizedAction = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detailID = reactionDetailID(
            messageID: extra.messageID,
            operatorUID: extra.operatorUID,
            emoji: normalizedEmoji
        )
        let isMine = currentUserIDs.contains(extra.operatorUID)
        let reactionIndex = message.reactions.firstIndex { $0.emoji == normalizedEmoji }
        let hasOperatorDetail = message.reactionDetails.contains { $0.id == detailID }

        if normalizedAction == "remove" {
            guard isDuplicate else {
                var didChange = false
                if let reactionIndex {
                    let shouldDecrement = !isMine || message.reactions[reactionIndex].reactedByMe
                    if shouldDecrement {
                        let nextCount = max(0, message.reactions[reactionIndex].count - 1)
                        if message.reactions[reactionIndex].count != nextCount {
                            message.reactions[reactionIndex].count = nextCount
                            didChange = true
                        }
                    }
                    if isMine, message.reactions[reactionIndex].reactedByMe {
                        message.reactions[reactionIndex].reactedByMe = false
                        didChange = true
                    }
                    if message.reactions[reactionIndex].count == 0 {
                        message.reactions.remove(at: reactionIndex)
                        didChange = true
                    }
                }
                let beforeDetailCount = message.reactionDetails.count
                message.reactionDetails.removeAll { $0.id == detailID }
                return didChange || message.reactionDetails.count != beforeDetailCount
            }
            let hasOwnReaction = reactionIndex.map { message.reactions[$0].reactedByMe } ?? false
            guard hasOperatorDetail || (isMine && hasOwnReaction) else { return false }
            if let reactionIndex {
                if hasOperatorDetail || (isMine && hasOwnReaction) {
                    message.reactions[reactionIndex].count = max(
                        0,
                        message.reactions[reactionIndex].count - 1
                    )
                }
                if isMine {
                    message.reactions[reactionIndex].reactedByMe = false
                }
                if message.reactions[reactionIndex].count == 0 {
                    message.reactions.remove(at: reactionIndex)
                }
            }
            message.reactionDetails.removeAll { $0.id == detailID }
            return true
        }

        var didChange = false
        if let reactionIndex {
            if !isDuplicate,
               !(isMine && message.reactions[reactionIndex].reactedByMe) {
                message.reactions[reactionIndex].count += 1
                didChange = true
            }
            if isMine, !message.reactions[reactionIndex].reactedByMe {
                message.reactions[reactionIndex].reactedByMe = true
                didChange = true
            }
        } else {
            message.reactions.append(
                Reaction(id: "\(extra.messageID)_\(normalizedEmoji)", emoji: normalizedEmoji, count: 1, reactedByMe: isMine)
            )
            didChange = true
        }
        if !hasOperatorDetail {
            message.reactionDetails.append(makeReactionDetail(extra, detailID))
            didChange = true
        }
        let operatorUID = extra.operatorUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDuplicate,
           !operatorUID.isEmpty,
           !currentUserIDs.contains(operatorUID),
           message.isOutgoing {
            if message.status != .read {
                message.status = .read
                didChange = true
            }
            if !message.readStateKnown {
                message.readStateKnown = true
                didChange = true
            }
            let nextReadCount = max(message.readCount ?? 0, 1)
            if message.readCount != nextReadCount {
                message.readCount = nextReadCount
                didChange = true
            }
        }
        return didChange
    }
    // JHT_MOD_END MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改结束

    func hasAppliedReactionExtraKey(_ key: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return false }
        return appliedReactionExtraKeys.contains(normalizedKey)
    }

    func appliedReactionExtraKeyCount() -> Int {
        appliedReactionExtraKeys.count
    }

    func hasAppliedReactionExtraKeys() -> Bool {
        !appliedReactionExtraKeys.isEmpty
    }

    func shouldShowHistorySyncErrorToast(
        conversationID: String,
        now: Date = Date(),
        throttleInterval: TimeInterval = 20
    ) -> Bool {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = max(0, throttleInterval)
        if let last = historySyncErrorToastTimesByConversationID[key],
           now.timeIntervalSince(last) < interval {
            return false
        }
        historySyncErrorToastTimesByConversationID[key] = now
        return true
    }

    func historySyncErrorToastTime(conversationID: String) -> Date? {
        let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return historySyncErrorToastTimesByConversationID[key]
    }

    func hasHistorySyncErrorToastTimes() -> Bool {
        !historySyncErrorToastTimesByConversationID.isEmpty
    }

    func isLocallyReadThrough(key: String, lastMessageSeq: Int64) -> Bool {
        guard lastMessageSeq > 0 else { return false }
        return locallyReadSeq(forKey: key) >= lastMessageSeq
    }

    func isMessageSyncInFlight(historyKey: String) -> Bool {
        messageSyncEngine.isInFlight(messageSyncRequest(historyKey: historyKey, reason: "status"))
    }

    func conversationPollingPlan(
        conversationID: String,
        shouldPollActiveConversation: Bool,
        historyKeyForConversation: (Conversation) -> String
    ) -> ConversationPollingPlan {
        guard let conversation = conversation(id: conversationID) else {
            return ConversationPollingPlan(
                conversationID: conversationID,
                historyKey: "",
                shouldPollActiveConversation: shouldPollActiveConversation,
                isMessageSyncInFlight: false
            )
        }
        let historyKey = historyKeyForConversation(conversation)
        return ConversationPollingPlan(
            conversationID: conversation.id,
            historyKey: historyKey,
            shouldPollActiveConversation: shouldPollActiveConversation,
            isMessageSyncInFlight: isMessageSyncInFlight(historyKey: historyKey)
        )
    }

    func beginMessageSync(historyKey: String, conversationID: String, showLoadingIndicator: Bool) -> Bool {
        let request = messageSyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "begin")
        let result = messageSyncEngine.begin(request)
        guard result.started else {
            if showLoadingIndicator {
                historyMessages[conversationID] = nil
            }
            return false
        }
        if showLoadingIndicator {
            historyMessages[conversationID] = nil
            historyLoadingIDs.insert(conversationID)
        }
        return true
    }

    func finishMessageSync(historyKey: String, conversationID: String, showLoadingIndicator: Bool) {
        if showLoadingIndicator {
            historyLoadingIDs.remove(conversationID)
        }
        messageSyncEngine.finish(messageSyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "finish"))
    }

    func historyLoadingConversationIDs() -> Set<String> {
        historyLoadingIDs
    }

    func hasHistoryLoadingIDs() -> Bool {
        !historyLoadingIDs.isEmpty
    }

    func historyMessagesByConversationID() -> [String: String] {
        historyMessages
    }

    func historyMessage(conversationID: String) -> String? {
        historyMessages[conversationID]
    }

    func hasHistoryMessages() -> Bool {
        !historyMessages.isEmpty
    }

    func directDisabledMessagesByConversationID() -> [String: String] {
        directDisabledMessages
    }

    func directDisabledMessage(conversationID: String) -> String? {
        directDisabledMessages[conversationID]
    }

    func hasDirectDisabledMessages() -> Bool {
        !directDisabledMessages.isEmpty
    }

    func applyingFriendConversationIDs() -> Set<String> {
        applyingFriendIDs
    }

    func isApplyingFriend(conversationID: String) -> Bool {
        applyingFriendIDs.contains(conversationID)
    }

    func hasApplyingFriendIDs() -> Bool {
        !applyingFriendIDs.isEmpty
    }

    func messageSidecarSyncKeyContext(
        tenantID: String?,
        imUID: String?,
        channelID: String,
        channelType: String,
        suffix: String,
        normalizeChannelID: (String, String) -> String
    ) -> MessageSidecarSyncKeyContext {
        MessageSidecarSyncKeyContext(
            tenantID: tenantID ?? "",
            imUID: imUID ?? "",
            channelID: channelID,
            channelType: channelType,
            normalizedChannelID: normalizeChannelID(channelID, channelType),
            suffix: suffix
        )
    }

    func readReceiptSidecarSyncTarget(
        channelID: String,
        channelType: String,
        readReceiptsEnabled: Bool,
        channelIDForConversation: (Conversation) -> String
    ) -> ReadReceiptSidecarSyncTarget? {
        // Delivery receipts remain a baseline capability when detailed read
        // identities/counts are licensed off, matching history backfill.
        _ = readReceiptsEnabled
        let target = ReadReceiptSidecarSyncTarget(channelID: channelID, channelType: channelType)
        guard !target.channelID.isEmpty else { return nil }
        let hasOutgoingMessages = conversations
            .first { conversation in
                conversation.id == target.channelID
                    || channelIDForConversation(conversation).trimmingCharacters(in: .whitespacesAndNewlines) == target.channelID
            }?
            .messages
            .contains { $0.isOutgoing } == true
        guard hasOutgoingMessages else { return nil }
        return target
    }

    func conversationReadStateKeyContext(
        channelID: String,
        channelType: String,
        normalizeChannelID: (String, String) -> String
    ) -> ConversationReadStateKeyContext {
        ConversationReadStateKeyContext(
            channelID: channelID,
            channelType: channelType,
            normalizedChannelID: normalizeChannelID(channelID, channelType)
        )
    }

    func conversationHistoryKeyContext(
        tenantID: String?,
        imUID: String?,
        conversationID: String
    ) -> ConversationHistoryKeyContext {
        ConversationHistoryKeyContext(
            tenantID: tenantID ?? "",
            imUID: imUID ?? "",
            conversationID: conversationID
        )
    }

    func activeConversationScopedStateKeyContext(
        tenantID: String?,
        imUID: String?,
        conversationID: String
    ) -> ActiveConversationScopedStateKeyContext {
        ActiveConversationScopedStateKeyContext(
            tenantID: tenantID ?? "",
            imUID: imUID ?? "",
            conversationID: conversationID
        )
    }

    func pinnedMessagesRefreshKeyContext(
        tenantID: String?,
        imUID: String?,
        conversationID: String,
        channelID: String
    ) -> PinnedMessagesRefreshKeyContext {
        PinnedMessagesRefreshKeyContext(
            tenantID: tenantID ?? "",
            imUID: imUID ?? "",
            conversationID: conversationID,
            channelID: channelID
        )
    }

    func isPinnedMessagesRefreshInFlight(refreshKey: String) -> Bool {
        guard !refreshKey.isEmpty else { return false }
        return messageSyncEngine.isInFlight(sidecarSyncRequest(operation: .pinnedMessages, syncKey: refreshKey, reason: "status"))
    }

    func beginPinnedMessagesRefresh(refreshKey: String) -> Bool {
        beginSidecarSync(operation: .pinnedMessages, syncKey: refreshKey)
    }

    func finishPinnedMessagesRefresh(refreshKey: String) {
        guard !refreshKey.isEmpty else { return }
        messageSyncEngine.finish(sidecarSyncRequest(operation: .pinnedMessages, syncKey: refreshKey, reason: "finish"))
    }

    func isMessageExtrasSyncInFlight(syncKey: String) -> Bool {
        guard !syncKey.isEmpty else { return false }
        return messageSyncEngine.isInFlight(sidecarSyncRequest(operation: .messageExtra, syncKey: syncKey, reason: "status"))
    }

    func beginMessageExtrasSync(syncKey: String) -> Bool {
        beginSidecarSync(operation: .messageExtra, syncKey: syncKey)
    }

    func beginMessageExtrasSync(_ command: MessageExtrasSyncCommand) -> Bool {
        beginMessageExtrasSync(syncKey: command.syncKey)
    }

    func finishMessageExtrasSync(syncKey: String) {
        guard !syncKey.isEmpty else { return }
        messageSyncEngine.finish(sidecarSyncRequest(operation: .messageExtra, syncKey: syncKey, reason: "finish"))
    }

    func messageExtrasSyncPlan(
        syncKey: String,
        channelID: String,
        channelType: String,
        afterVersion: Int64 = 0,
        limit: Int = 100
    ) -> MessageExtrasSyncPlan {
        let command = MessageExtrasSyncCommand(
            syncKey: syncKey,
            channelID: channelID,
            channelType: channelType,
            afterVersion: afterVersion,
            limit: limit
        )
        guard !command.syncKey.isEmpty else {
            return .skip(command, reason: "empty message extras key")
        }
        guard !isMessageExtrasSyncInFlight(syncKey: command.syncKey) else {
            return .skip(command, reason: "message extras already in flight")
        }
        return .sync(command)
    }

    func isMessageReceiptsSyncInFlight(syncKey: String) -> Bool {
        guard !syncKey.isEmpty else { return false }
        return messageSyncEngine.isInFlight(sidecarSyncRequest(operation: .readReceipt, syncKey: syncKey, reason: "status"))
    }

    func beginMessageReceiptsSync(syncKey: String) -> Bool {
        beginMessageReceiptsSyncClaim(.init(syncKey: syncKey, channelID: "", channelType: "")) != nil
    }

    func beginMessageReceiptsSync(_ command: MessageReceiptsSyncCommand) -> Bool {
        beginMessageReceiptsSyncClaim(command) != nil
    }

    func beginMessageReceiptsSyncClaim(_ command: MessageReceiptsSyncCommand) -> MessageReceiptsSyncClaim? {
        guard beginSidecarSync(operation: .readReceipt, syncKey: command.syncKey) else { return nil }
        nextReceiptSyncGeneration &+= 1
        activeReceiptSyncGenerations[command.syncKey] = nextReceiptSyncGeneration
        return MessageReceiptsSyncClaim(syncKey: command.syncKey, generation: nextReceiptSyncGeneration)
    }

    func isCurrentMessageReceiptsSync(_ claim: MessageReceiptsSyncClaim) -> Bool {
        activeReceiptSyncGenerations[claim.syncKey] == claim.generation
    }

    func finishMessageReceiptsSync(_ claim: MessageReceiptsSyncClaim) {
        guard isCurrentMessageReceiptsSync(claim) else { return }
        finishMessageReceiptsSync(syncKey: claim.syncKey)
    }

    func finishMessageReceiptsSync(syncKey: String) {
        guard !syncKey.isEmpty else { return }
        activeReceiptSyncGenerations.removeValue(forKey: syncKey)
        messageSyncEngine.finish(sidecarSyncRequest(operation: .readReceipt, syncKey: syncKey, reason: "finish"))
    }

    func messageReceiptsSyncPlan(
        syncKey: String,
        channelID: String,
        channelType: String,
        afterSeq: Int64 = 0,
        receiptType: String = "read",
        limit: Int = 100
    ) -> MessageReceiptsSyncPlan {
        let command = MessageReceiptsSyncCommand(
            syncKey: syncKey,
            channelID: channelID,
            channelType: channelType,
            afterSeq: afterSeq,
            receiptType: receiptType,
            limit: limit
        )
        guard !command.syncKey.isEmpty else {
            return .skip(command, reason: "empty read receipt key")
        }
        guard !isMessageReceiptsSyncInFlight(syncKey: command.syncKey) else {
            return .skip(command, reason: "read receipts already in flight")
        }
        return .sync(command)
    }

    func isReadAckSyncInFlight(syncKey: String) -> Bool {
        guard !syncKey.isEmpty else { return false }
        return messageSyncEngine.isInFlight(sidecarSyncRequest(operation: .readAck, syncKey: syncKey, reason: "status"))
    }

    func readAckSyncPlan(syncKey: String, targetSeq: Int64? = nil) -> ReadAckSyncPlan {
        let command = ReadAckCommand(syncKey: syncKey, targetSeq: targetSeq)
        guard !syncKey.isEmpty else {
            return .skip(command, reason: "empty read ack key")
        }
        if let targetSeq = command.targetSeq {
            if targetSeq <= locallyReadSeq(forKey: syncKey) {
                return .clearLocally(command)
            }
            if targetSeq <= max(
                pendingReadAckSeqs[syncKey] ?? 0,
                queuedReadAckSeqs[syncKey] ?? 0
            ) {
                return .skip(command, reason: "read ack target already pending")
            }
        }
        if isReadAckSyncInFlight(syncKey: syncKey) {
            return .queue(command)
        }
        return .remoteAck(command)
    }

    func beginReadAckSync(_ command: ReadAckCommand) -> Bool {
        beginReadAckSyncClaim(command) != nil
    }

    func beginReadAckSync(syncKey: String, targetSeq: Int64? = nil) -> Bool {
        beginReadAckSyncClaim(ReadAckCommand(syncKey: syncKey, targetSeq: targetSeq)) != nil
    }

    func beginReadAckSyncClaim(_ command: ReadAckCommand) -> ReadAckSyncClaim? {
        let syncKey = command.syncKey
        guard !syncKey.isEmpty else { return nil }
        if let targetSeq = command.targetSeq {
            let boundedTargetSeq = max(0, targetSeq)
            guard boundedTargetSeq > locallyReadSeq(forKey: syncKey) else { return nil }
            guard boundedTargetSeq > (pendingReadAckSeqs[syncKey] ?? 0) else { return nil }
        }
        let didStart = beginSidecarSync(operation: .readAck, syncKey: syncKey)
        guard didStart else { return nil }
        if let targetSeq = command.targetSeq {
            pendingReadAckSeqs[syncKey] = max(0, targetSeq)
        }
        nextReadAckGeneration &+= 1
        let generation = nextReadAckGeneration
        activeReadAckGenerations[syncKey] = generation
        return ReadAckSyncClaim(command: command, generation: generation)
    }

    @discardableResult
    func queueReadAckSync(_ command: ReadAckCommand) -> Bool {
        guard !command.syncKey.isEmpty,
              let targetSeq = command.targetSeq,
              isReadAckSyncInFlight(syncKey: command.syncKey),
              targetSeq > locallyReadSeq(forKey: command.syncKey),
              targetSeq > max(
                  pendingReadAckSeqs[command.syncKey] ?? 0,
                  queuedReadAckSeqs[command.syncKey] ?? 0
              ) else { return false }
        queuedReadAckSeqs[command.syncKey] = targetSeq
        return true
    }

    @discardableResult
    func finishReadAckSync(_ claim: ReadAckSyncClaim) -> ReadAckCommand? {
        let syncKey = claim.command.syncKey
        guard !syncKey.isEmpty,
              activeReadAckGenerations[syncKey] == claim.generation else { return nil }
        activeReadAckGenerations.removeValue(forKey: syncKey)
        pendingReadAckSeqs.removeValue(forKey: syncKey)
        messageSyncEngine.finish(sidecarSyncRequest(operation: .readAck, syncKey: syncKey, reason: "finish"))
        guard let queuedTargetSeq = queuedReadAckSeqs.removeValue(forKey: syncKey),
              queuedTargetSeq > locallyReadSeq(forKey: syncKey) else { return nil }
        return ReadAckCommand(syncKey: syncKey, targetSeq: queuedTargetSeq)
    }

    @discardableResult
    func finishReadAckSync(syncKey: String) -> ReadAckCommand? {
        guard let generation = activeReadAckGenerations[syncKey] else { return nil }
        return finishReadAckSync(
            ReadAckSyncClaim(
                command: ReadAckCommand(syncKey: syncKey, targetSeq: pendingReadAckSeqs[syncKey]),
                generation: generation
            )
        )
    }

    private func beginSidecarSync(operation: SyncEngineOperation, syncKey: String) -> Bool {
        guard !syncKey.isEmpty else { return false }
        return messageSyncEngine.begin(sidecarSyncRequest(operation: operation, syncKey: syncKey, reason: "begin")).started
    }

    private func messageSyncRequest(
        historyKey: String,
        conversationID: String? = nil,
        reason: String
    ) -> SyncEngineRequest {
        SyncEngineRequest(
            operation: .conversationMessages,
            conversationID: conversationID,
            historyKey: historyKey,
            reason: reason
        )
    }

    private func olderHistorySyncRequest(historyKey: String, conversationID: String, reason: String) -> SyncEngineRequest {
        SyncEngineRequest(
            operation: .olderMessages,
            conversationID: conversationID,
            historyKey: historyKey,
            reason: reason
        )
    }

    private func sidecarSyncRequest(operation: SyncEngineOperation, syncKey: String, reason: String) -> SyncEngineRequest {
        SyncEngineRequest(
            operation: operation,
            historyKey: syncKey,
            reason: reason
        )
    }

    @discardableResult
    func applyRemoteEditExtra(
        _ extra: RemoteMessageExtra,
        normalizedChannelID: String,
        channelIDForConversation: (Conversation) -> String
    ) -> Bool {
        let messageID = extra.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedText = editedText(from: extra.payload)
		let incomingRevision = extra.editRevision
		guard !messageID.isEmpty, !editedText.isEmpty, incomingRevision > 0 else { return false }
        var didApply = false
        for cIndex in conversations.indices {
            let conversationChannelID = channelIDForConversation(conversations[cIndex])
            guard normalizedChannelID.isEmpty
                    || conversationChannelID == normalizedChannelID
                    || conversations[cIndex].id == normalizedChannelID else { continue }
            let messageIndex = conversations[cIndex].messages.firstIndex { message in
                message.id == messageID || (extra.channelSeq > 0 && message.channelSeq == extra.channelSeq)
            }
            guard let mIndex = messageIndex else { continue }
			let current = conversations[cIndex].messages[mIndex]
			let normalizedContentType = current.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard current.kind == .text,
			      normalizedContentType.isEmpty || ["text", "plain_text", "text/plain"].contains(normalizedContentType),
			      current.status != .recalled,
			      !current.isDeletedLocally,
			      incomingRevision > current.editRevision else { continue }
            conversations[cIndex].messages[mIndex].text = editedText
            conversations[cIndex].messages[mIndex].isEdited = true
			conversations[cIndex].messages[mIndex].editRevision = incomingRevision
            updateConversationLatestFromMessages(at: cIndex)
            didApply = true
        }
        return didApply
    }

    @discardableResult
    func applyRemotePinExtra(
        _ extra: RemoteMessageExtra,
        normalizedChannelID: String,
        channelIDForConversation: (Conversation) -> String
    ) -> Bool {
        guard !extra.messageID.isEmpty else { return false }
        let action = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPinned = extra.payload["pinned"]?.boolValue ?? ["pin", "pinned", "true", "1"].contains(action)
        var didApply = false
        for cIndex in conversations.indices {
            let conversationChannelID = channelIDForConversation(conversations[cIndex])
            guard normalizedChannelID.isEmpty
                    || conversationChannelID == normalizedChannelID
                    || conversations[cIndex].id == normalizedChannelID else { continue }
            if let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }) {
                conversations[cIndex].messages[mIndex].isPinned = isPinned
                didApply = true
            }
        }
        return didApply
    }

    private func editedText(from payload: [String: JSONValue]) -> String {
        if let nestedPayload = payload["payload"]?.objectValue {
            let nestedText = editedTextValue(from: nestedPayload)
            if !nestedText.isEmpty {
                return nestedText
            }
        }
        return editedTextValue(from: payload)
    }

    private func editedTextValue(from payload: [String: JSONValue]) -> String {
        for key in ["text", "body", "content", "message"] {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    func markReactionReminderIfNeeded(
        _ extra: RemoteMessageExtra,
        currentUserIDs: Set<String>,
        activeConversationID: String?,
        channelIDForConversation: (Conversation) -> String
    ) {
        guard extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "remove" else { return }
        let operatorUID = extra.operatorUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operatorUID.isEmpty, !currentUserIDs.contains(operatorUID) else { return }
        guard let index = conversations.firstIndex(where: { conversation in
            conversation.messages.contains(where: { $0.id == extra.messageID })
                || conversation.id == extra.channelID
                || channelIDForConversation(conversation) == extra.channelID
        }) else { return }
        conversations[index].hasUnreadReaction = true
        if activeConversationID != conversations[index].id {
            conversations[index].unread += 1
            conversations[index].unreadReactionCount += 1
        }
    }

    @discardableResult
    func applyMessageReaction(
        messageID: String,
        emoji: String,
        operatorUID: String,
        action: String,
        currentUserIDs: Set<String>
    ) -> Bool {
        let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageID.isEmpty, !normalizedEmoji.isEmpty else { return false }
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isMine = currentUserIDs.contains(operatorUID)
        for cIndex in conversations.indices {
            guard let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { continue }
            if let rIndex = conversations[cIndex].messages[mIndex].reactions.firstIndex(where: { $0.emoji == normalizedEmoji }) {
                if normalizedAction == "remove" {
                    let shouldDecrement = !isMine || conversations[cIndex].messages[mIndex].reactions[rIndex].reactedByMe
                    if shouldDecrement {
                        conversations[cIndex].messages[mIndex].reactions[rIndex].count = max(0, conversations[cIndex].messages[mIndex].reactions[rIndex].count - 1)
                    }
                    if isMine {
                        conversations[cIndex].messages[mIndex].reactions[rIndex].reactedByMe = false
                    }
                    if conversations[cIndex].messages[mIndex].reactions[rIndex].count == 0 {
                        conversations[cIndex].messages[mIndex].reactions.remove(at: rIndex)
                    }
                } else {
                    if !(isMine && conversations[cIndex].messages[mIndex].reactions[rIndex].reactedByMe) {
                        conversations[cIndex].messages[mIndex].reactions[rIndex].count += 1
                    }
                    if isMine {
                        conversations[cIndex].messages[mIndex].reactions[rIndex].reactedByMe = true
                    }
                }
            } else if normalizedAction != "remove" {
                conversations[cIndex].messages[mIndex].reactions.append(
                    Reaction(id: "\(messageID)_\(normalizedEmoji)", emoji: normalizedEmoji, count: 1, reactedByMe: isMine)
                )
            }
            return true
        }
        return false
    }

    @discardableResult
    func applyMessageReactionDetail(
        _ extra: RemoteMessageExtra,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> Bool {
        let normalizedEmoji = extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.messageID.isEmpty, !normalizedEmoji.isEmpty else { return false }
        let normalizedAction = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for cIndex in conversations.indices {
            guard let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }) else { continue }
            let detailID = reactionDetailID(messageID: extra.messageID, operatorUID: extra.operatorUID, emoji: normalizedEmoji)
            if normalizedAction == "remove" {
                conversations[cIndex].messages[mIndex].reactionDetails.removeAll { $0.id == detailID }
            } else if !conversations[cIndex].messages[mIndex].reactionDetails.contains(where: { $0.id == detailID }) {
                conversations[cIndex].messages[mIndex].reactionDetails.append(makeReactionDetail(extra, detailID))
            }
            return true
        }
        return false
    }

    func applyReactionReadStateIfNeeded(_ extra: RemoteMessageExtra, currentUserIDs: Set<String>) {
        let operatorUID = extra.operatorUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operatorUID.isEmpty,
              !currentUserIDs.contains(operatorUID),
              extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "remove" else { return }
        for cIndex in conversations.indices {
            guard let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }),
                  conversations[cIndex].messages[mIndex].isOutgoing else { continue }
            conversations[cIndex].messages[mIndex].status = .read
            conversations[cIndex].messages[mIndex].readStateKnown = true
            if conversations[cIndex].messages[mIndex].readCount == nil {
                conversations[cIndex].messages[mIndex].readCount = 1
            } else {
                conversations[cIndex].messages[mIndex].readCount = max(conversations[cIndex].messages[mIndex].readCount ?? 0, 1)
            }
            return
        }
    }

    private func reactionDetailID(messageID: String, operatorUID: String, emoji: String) -> String {
        [messageID, operatorUID, emoji]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private func groupConversationIndex(
        groupID: String,
        groupName: String,
        matchByTitle: Bool,
        channelIDForConversation: (Conversation) -> String
    ) -> Int? {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.firstIndex { conversation in
            if !normalizedGroupID.isEmpty,
               conversation.id == normalizedGroupID || channelIDForConversation(conversation) == normalizedGroupID {
                return true
            }
            if matchByTitle,
               !normalizedGroupName.isEmpty,
               conversation.kind == .group,
               conversation.title == normalizedGroupName {
                return true
            }
            return false
        }
    }

    private func conversationSortTimestamp(_ conversation: Conversation) -> TimeInterval {
        if conversation.sortTimestamp > 0 {
            return conversation.sortTimestamp
        }
        if let latestDate = latestConfirmedMessage(in: conversation.messages).flatMap(effectiveCreatedAt) {
            return latestDate.timeIntervalSince1970
        }
        return 0
    }

    private func effectiveCreatedAt(for message: ChatMessage) -> Date? {
        message.createdAt
    }

    private func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }

    private func messageTimelinePrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.channelSeq > 0, rhs.channelSeq > 0, lhs.channelSeq != rhs.channelSeq {
            return lhs.channelSeq < rhs.channelSeq
        }
        let lhsDate = lhs.createdAt ?? Date.distantPast
        let rhsDate = rhs.createdAt ?? Date.distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }

    private func mergeExistingRemoteState(from previous: ChatMessage, into message: inout ChatMessage) {
		if previous.editRevision >= message.editRevision && previous.editRevision > 0 {
			message.text = previous.text
			message.isEdited = previous.isEdited
			message.editRevision = previous.editRevision
		}
        if message.senderAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.senderAvatarURL = previous.senderAvatarURL
        }
        if message.senderAvatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.senderAvatarVersion = previous.senderAvatarVersion
        }
        if message.senderAvatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.senderAvatarUpdatedAt = previous.senderAvatarUpdatedAt
        }
        if message.senderAvatarSeed == 0 {
            message.senderAvatarSeed = previous.senderAvatarSeed
        }
        message.reactions = previous.reactions
        message.reactionDetails = previous.reactionDetails
        message.readBy = previous.readBy
        message.unreadBy = previous.unreadBy
        message.readCount = previous.readCount
        message.readStateKnown = previous.readStateKnown
        message.deliveryStateKnown = message.deliveryStateKnown || previous.deliveryStateKnown
        message.canViewReadDetails = previous.canViewReadDetails
        if previous.status == .read || (previous.readCount ?? 0) > 0 || !previous.readBy.isEmpty {
            message.status = .read
        }
    }

    private func normalizedCompletedAttachmentStatus(_ remoteStatus: String) -> String {
        let trimmed = remoteStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "uploaded" : trimmed
    }

    private func retainedRemoteAttachmentURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.isFileURL {
            return ""
        }
        return rawValue
    }

    private func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

    private func attachmentMediaCategory(for message: ChatMessage) -> String {
        let explicit = message.attachmentMediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !explicit.isEmpty { return explicit }
        let previewKind = message.attachmentPreviewKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["image", "video", "pdf"].contains(previewKind) {
            return previewKind
        }
        return inferredAttachmentMediaCategory(
            kind: message.kind,
            name: message.attachmentName ?? message.text,
            mimeType: attachmentMimeType(from: message)
        )
    }

    private func attachmentMimeType(from message: ChatMessage) -> String {
        let explicit = message.attachmentMimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !explicit.isEmpty {
            return explicit
        }
        if let value = message.attachmentMeta?
            .components(separatedBy: " · ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           value.contains("/") {
            return value.lowercased()
        }
        return message.kind == .image ? "image/jpeg" : "application/octet-stream"
    }

    private func inferredAttachmentMediaCategory(kind: MessageKind, name: String, mimeType: String) -> String {
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if kind == .image || normalizedMime.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(ext) {
            return "image"
        }
        if normalizedMime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(ext) {
            return "video"
        }
        if normalizedMime.contains("pdf") || ext == "pdf" {
            return "pdf"
        }
        if normalizedMime.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext) {
            return "audio"
        }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
            return "archive"
        }
        return "file"
    }

    func applyRemoteReadSummary(
        from remote: RemoteMessage,
        to message: inout ChatMessage,
        readReceiptsEnabled: Bool
    ) {
        guard message.isOutgoing else { return }
        guard readReceiptsEnabled else {
            stripReadReceiptDetails(from: &message)
            return
        }
        let normalizedStatus = remote.readStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasSummary = !normalizedStatus.isEmpty || remote.readCount != nil || remote.readAt != nil
        guard hasSummary else { return }
        let summaryReadCount = max(0, remote.readCount ?? 0)
        let isRead = normalizedStatus == "read" || summaryReadCount > 0 || remote.readAt != nil
        message.readStateKnown = true
        if let remoteReadCount = remote.readCount {
            message.readCount = max(message.readCount ?? 0, max(0, remoteReadCount))
        }
        if isRead {
            message.status = .read
            return
        }
        if message.status != .read {
            message.status = .sent
            if message.readCount == nil {
                message.readCount = 0
            }
        }
    }

    func applyRemoteReadSummary(
        from remote: RemoteMessage,
        toMessagesIn conversation: inout Conversation,
        readReceiptsEnabled: Bool
    ) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == remote.messageID }) else { return }
        applyRemoteReadSummary(from: remote, to: &conversation.messages[index], readReceiptsEnabled: readReceiptsEnabled)
    }

    @discardableResult
    func applyRemoteReadReceiptDetails(
        response: RemoteMessageReadReceiptResponse,
        messageID: String,
        conversationID: String,
        makeReadReceipt: (RemoteMessageReceipt, Conversation) -> ReadReceipt,
        makeUnreadReceipt: (RemoteMessageReadParticipant, Conversation) -> ReadReceipt,
        makeReactionDetail: (RemoteMessageReactionReceipt) -> ReactionDetail
    ) -> Bool {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == normalizedMessageID }),
              conversations[cIndex].messages[mIndex].isOutgoing else { return false }
        let conversation = conversations[cIndex]
        let previous = conversation.messages[mIndex]
        let readReceipts = response.items
            .filter { normalizedReadReceiptType($0.receiptType) == "read" && !$0.imUID.isEmpty }
            .map { makeReadReceipt($0, conversation) }
        let effectiveReadReceipts = readReceipts.isEmpty ? previous.readBy : readReceipts
        let unreadParticipants = filteredUnreadParticipants(
            from: response,
            effectiveReadReceipts: effectiveReadReceipts
        )
        let unreadReceipts = unreadParticipants.map { makeUnreadReceipt($0, conversation) }
        let responseReadCount = response.readCount ?? readReceipts.count
        let derivedUnreadCount = normalizedUnreadCount(
            response: response,
            conversation: conversation,
            readCount: responseReadCount,
            visibleUnreadCount: unreadReceipts.count
        )
        let hadConfirmedRead = previous.status == .read
            || (previous.readStateKnown && previous.status != .sent)
            || !previous.readBy.isEmpty
            || (previous.readCount ?? 0) > 0
        let isRead = response.read || responseReadCount > 0 || hadConfirmedRead
        let canViewDetails = response.canViewDetails || response.hasReceiptDetails
        var updated = previous
        if canViewDetails {
            updated.readBy = effectiveReadReceipts
            let uniqueReadCount = Set(readReceipts.map(\.user.id)).count
            updated.readCount = max(response.readCount ?? 0, uniqueReadCount, previous.readCount ?? 0)
            updated.unreadBy = unreadReceipts
            updated.unreadCount = derivedUnreadCount
        } else {
            updated.readBy = []
            updated.readCount = nil
            updated.unreadBy = []
            updated.unreadCount = nil
        }
        let reactionDetails = response.reactions.map { makeReactionDetail($0) }
        updated.reactionDetails = reactionDetails.isEmpty ? previous.reactionDetails : reactionDetails
        updated.readStateKnown = true
        updated.canViewReadDetails = canViewDetails
        if isRead {
            updated.status = .read
        } else if updated.status == .read {
            updated.status = .sent
        }
        guard updated != previous else { return false }
        conversations[cIndex].messages[mIndex] = updated
        return true
    }

    private func inferredUnreadCount(response: RemoteMessageReadReceiptResponse, conversation: Conversation, readCount: Int) -> Int? {
        if let unreadCount = response.unreadCount {
            return max(0, unreadCount)
        }
        if let targetCount = response.targetCount {
            return max(0, targetCount - readCount)
        }
        if let memberCount = response.memberCount, memberCount > 0 {
            return max(0, memberCount - 1 - readCount)
        }
        return nil
    }

    private func normalizedUnreadCount(
        response: RemoteMessageReadReceiptResponse,
        conversation: Conversation,
        readCount: Int,
        visibleUnreadCount: Int
    ) -> Int? {
        guard let inferredCount = inferredUnreadCount(response: response, conversation: conversation, readCount: readCount) else {
            return visibleUnreadCount > 0 ? visibleUnreadCount : nil
        }
        if response.unreadCount != nil, inferredCount == response.unreadItems.count {
            return visibleUnreadCount
        }
        return max(inferredCount, visibleUnreadCount)
    }

    private func filteredUnreadParticipants(
        from response: RemoteMessageReadReceiptResponse,
        effectiveReadReceipts: [ReadReceipt]
    ) -> [RemoteMessageReadParticipant] {
        let readIDs = Set(response.items
            .filter { normalizedReadReceiptType($0.receiptType) == "read" }
            .map { normalizedReadReceiptIdentity($0.imUID) }
            .filter { !$0.isEmpty })
        let effectiveReadIDs = Set(effectiveReadReceipts
            .map { normalizedReadReceiptIdentity($0.user.id) }
            .filter { !$0.isEmpty })
        let allReadIDs = readIDs.union(effectiveReadIDs)
        return response.unreadItems.filter { participant in
            let participantID = normalizedReadReceiptIdentity(participant.imUID)
            if !participantID.isEmpty, allReadIDs.contains(participantID) {
                return false
            }
            if let readAt = participant.readAt?.trimmingCharacters(in: .whitespacesAndNewlines), !readAt.isEmpty {
                return false
            }
            return true
        }
    }

    private func normalizedReadReceiptIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedReadReceiptType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @discardableResult
    func applyRemoteReadReceipts(
        _ receipts: [RemoteMessageReceipt],
        channelID: String,
        readReceiptsEnabled: Bool,
        channelIDForConversation: (Conversation) -> String,
        makeReadReceipt: (RemoteMessageReceipt, Conversation) -> ReadReceipt
    ) -> Bool {
        guard !receipts.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == channelID || channelIDForConversation($0) == channelID }) else { return false }
        // JHT_MOD_BEGIN CHAT_READ_RECEIPT_APPLY_INDEX_PERF_20260912 - 修改开始：回执应用用索引匹配目标消息，减少消息页主线程扫描与整表拷贝
        let messageReceipts = receipts.enumerated().compactMap { order, receipt -> (order: Int, receipt: RemoteMessageReceipt)? in
            let receiptType = normalizedReadReceiptType(receipt.receiptType)
            guard (receiptType == "delivered" || (receiptType == "read" && readReceiptsEnabled)) &&
                    (!receipt.messageID.isEmpty || receipt.channelSeq > 0) else {
                return nil
            }
            return (order, receipt)
        }
        guard !messageReceipts.isEmpty else { return false }

        var exactReceiptsByMessageID: [String: [(order: Int, receipt: RemoteMessageReceipt)]] = [:]
        var sequenceReceiptEntries: [(order: Int, channelSeq: Int64, receipt: RemoteMessageReceipt)] = []
        exactReceiptsByMessageID.reserveCapacity(messageReceipts.count)
        sequenceReceiptEntries.reserveCapacity(messageReceipts.count)
        for entry in messageReceipts {
            if !entry.receipt.messageID.isEmpty {
                exactReceiptsByMessageID[entry.receipt.messageID, default: []].append(entry)
            } else if entry.receipt.channelSeq > 0 {
                sequenceReceiptEntries.append((entry.order, entry.receipt.channelSeq, entry.receipt))
            }
        }

        var conversation = conversations[cIndex]
        var didChange = false
        for mIndex in conversation.messages.indices {
            let originalMessage = conversation.messages[mIndex]
            guard originalMessage.isOutgoing else { continue }

            var matchedEntries = exactReceiptsByMessageID[originalMessage.id] ?? []
            if originalMessage.channelSeq > 0 {
                for entry in sequenceReceiptEntries where originalMessage.channelSeq <= entry.channelSeq {
                    matchedEntries.append((entry.order, entry.receipt))
                }
            }
            guard !matchedEntries.isEmpty else { continue }
            if matchedEntries.count > 1 {
                matchedEntries.sort { $0.order < $1.order }
            }
            let items = matchedEntries.map { $0.receipt }

            var message = originalMessage
            message.deliveryStateKnown = true
            let readItems = items.filter { normalizedReadReceiptType($0.receiptType) == "read" }
            guard !readItems.isEmpty else {
                if message.status != .read { message.status = .sent }
                if message != originalMessage {
                    conversation.messages[mIndex] = message
                    didChange = true
                }
                continue
            }
            let detailedItems = readItems.filter { !$0.imUID.isEmpty }
            let existingReadUserIDs = Set(message.readBy.map(\.user.id))
            message.status = .read
            message.readStateKnown = true
            message.canViewReadDetails = message.canViewReadDetails || !detailedItems.isEmpty
            if detailedItems.isEmpty {
                if message.readCount == nil {
                    message.readCount = message.canViewReadDetails ? max(message.readBy.count, 1) : nil
                }
            } else {
                let nextReadReceipts = detailedItems.map { makeReadReceipt($0, conversation) }
                var mergedReadReceiptsByUser: [String: ReadReceipt] = [:]
                for receipt in message.readBy {
                    mergedReadReceiptsByUser[receipt.user.id] = receipt
                }
                for receipt in nextReadReceipts {
                    mergedReadReceiptsByUser[receipt.user.id] = receipt
                }
                message.readBy = Array(mergedReadReceiptsByUser.values)
                    .sorted { lhs, rhs in
                        if lhs.time != rhs.time { return lhs.time < rhs.time }
                        return lhs.user.id < rhs.user.id
                    }
                let nextReadUserIDs = Set(nextReadReceipts
                    .map { normalizedReadReceiptIdentity($0.user.id) }
                    .filter { !$0.isEmpty })
                if !nextReadUserIDs.isEmpty {
                    message.unreadBy.removeAll { nextReadUserIDs.contains(normalizedReadReceiptIdentity($0.user.id)) }
                }
                message.readCount = max(message.readCount ?? 0, Set(message.readBy.map(\.user.id)).count)
                let newlyReadCount = Set(nextReadReceipts.map { normalizedReadReceiptIdentity($0.user.id) })
                    .subtracting(existingReadUserIDs.map(normalizedReadReceiptIdentity))
                    .count
                if let unreadCount = message.unreadCount, newlyReadCount > 0 {
                    message.unreadCount = max(0, unreadCount - newlyReadCount)
                }
            }
            if message != originalMessage {
                conversation.messages[mIndex] = message
                didChange = true
            }
        }
        guard didChange else { return false }
        conversations[cIndex] = conversation
        return true
        // JHT_MOD_END CHAT_READ_RECEIPT_APPLY_INDEX_PERF_20260912 - 修改结束
    }

    @discardableResult
    func stripReadReceiptDetailsFromAllMessages() -> Bool {
        var next = conversations
        var didChange = false
        for cIndex in next.indices {
            for mIndex in next[cIndex].messages.indices {
                var message = next[cIndex].messages[mIndex]
                let before = message
                stripReadReceiptDetails(from: &message)
                if message != before {
                    next[cIndex].messages[mIndex] = message
                    didChange = true
                }
            }
        }
        if didChange {
            conversations = next
        }
        return didChange
    }

    func stripReadReceiptDetails(from message: inout ChatMessage) {
        message.readBy = []
        message.unreadBy = []
        message.readCount = nil
        message.unreadCount = nil
        message.readStateKnown = false
        message.canViewReadDetails = false
        message.reactionDetails = []
        if message.status == .read {
            message.status = .sent
        }
    }

    func isHistoryLoading(conversationID: String) -> Bool {
        historyLoadingIDs.contains(conversationID)
    }

    func hasReachedHistoryStart(historyKey: String) -> Bool {
        historyReachedStartKeys.contains(historyKey)
    }

    func hasHistoryReachedStartKeys() -> Bool {
        !historyReachedStartKeys.isEmpty
    }

    func historyBackfillAfterSeq(historyKey: String, defaultValue: Int64) -> Int64 {
        historyBackfillAfterSeqs[historyKey] ?? defaultValue
    }

    func hasHistoryBackfillAfterSeqs() -> Bool {
        !historyBackfillAfterSeqs.isEmpty
    }

    func hasHistoryLoadRequestTimes() -> Bool {
        !historyLoadRequestTimes.isEmpty
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_DIRECT_UNAVAILABLE_DEDUPE - 修改开始：好友不可用状态重复写入去重，action/context 变化仍通知 UI
    @discardableResult
    private func setHistoryMessageIfChanged(conversationID: String, message: String?) -> Bool {
        guard historyMessages[conversationID] != message else { return false }
        historyMessages[conversationID] = message
        return true
    }

    @discardableResult
    private func setDirectDisabledMessageIfChanged(conversationID: String, message: String?) -> Bool {
        guard directDisabledMessages[conversationID] != message else { return false }
        directDisabledMessages[conversationID] = message
        return true
    }

    @discardableResult
    private func setDirectFriendRequestContextIfChanged(
        conversationID: String,
        context: DirectFriendRequestContext?
    ) -> Bool {
        guard directFriendRequestContexts[conversationID] != context else { return false }
        objectWillChange.send()
        directFriendRequestContexts[conversationID] = context
        return true
    }

    func setHistoryMessage(conversationID: String, message: String?) {
        setHistoryMessageIfChanged(conversationID: conversationID, message: message)
    }

    func setDirectDisabledMessage(conversationID: String, message: String?) {
        setDirectDisabledMessageIfChanged(conversationID: conversationID, message: message)
    }

    func directFriendRequestContext(conversationID: String) -> DirectFriendRequestContext? {
        directFriendRequestContexts[conversationID]
    }

    func hasDirectFriendRequestContexts() -> Bool {
        !directFriendRequestContexts.isEmpty
    }

    func setDirectFriendRequestContext(conversationID: String, context: DirectFriendRequestContext?) {
        setDirectFriendRequestContextIfChanged(conversationID: conversationID, context: context)
    }

    func markDirectConversationUnavailable(
        _ conversation: Conversation,
        context: DirectFriendRequestContext,
        fallbackMessage: String? = nil
    ) {
        guard conversation.kind == .direct else { return }
        let message = fallbackMessage ?? context.disabledMessage
        setDirectFriendRequestContextIfChanged(conversationID: conversation.id, context: context)
        setDirectDisabledMessageIfChanged(conversationID: conversation.id, message: message)
        setHistoryMessageIfChanged(conversationID: conversation.id, message: message)
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            if conversations[index].subtitle != "需要好友关系" {
                conversations[index].subtitle = "需要好友关系"
            }
            if conversations[index].unread != 0 {
                conversations[index].unread = 0
            }
        }
    }

    func clearDirectFriendRequestContext(conversationID: String) {
        setDirectFriendRequestContextIfChanged(conversationID: conversationID, context: nil)
    }

    func clearHistoryAndDirectDisabledMessages(conversationID: String) {
        setHistoryMessageIfChanged(conversationID: conversationID, message: nil)
        setDirectDisabledMessageIfChanged(conversationID: conversationID, message: nil)
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_DIRECT_UNAVAILABLE_DEDUPE - 修改结束

    func beginApplyingFriend(conversationID: String) -> Bool {
        guard !conversationID.isEmpty, !applyingFriendIDs.contains(conversationID) else { return false }
        applyingFriendIDs.insert(conversationID)
        return true
    }

    func finishApplyingFriend(conversationID: String) {
        applyingFriendIDs.remove(conversationID)
    }

    func markHistoryUnavailable(historyKey: String, conversationID: String, message: String) {
        historyReachedStartKeys.insert(historyKey)
        historyMessages[conversationID] = message
    }

    func beginOlderHistoryLoad(historyKey: String, conversationID: String, now: Date, throttleInterval: TimeInterval) -> Bool {
        if let lastRequestTime = historyLoadRequestTimes[historyKey],
           now.timeIntervalSince(lastRequestTime) < throttleInterval {
            return false
        }
        let request = olderHistorySyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "begin")
        guard messageSyncEngine.begin(request).started else {
            return false
        }
        historyLoadRequestTimes[historyKey] = now
        historyMessages[conversationID] = nil
        historyLoadingIDs.insert(conversationID)
        return true
    }

    func finishOlderHistoryLoad(historyKey: String? = nil, conversationID: String) {
        historyLoadingIDs.remove(conversationID)
        if let historyKey {
            messageSyncEngine.finish(olderHistorySyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "finish"))
        }
    }

    func markOlderHistoryReachedStart(historyKey: String, conversationID: String, message: String) {
        historyBackfillAfterSeqs.removeValue(forKey: historyKey)
        historyReachedStartKeys.insert(historyKey)
        historyMessages[conversationID] = message
    }

    func markOlderHistoryNeedsContinue(
        historyKey: String,
        conversationID: String,
        nextBackfillAfterSeq: Int64,
        pageLimit: Int,
        message: String
    ) {
        historyBackfillAfterSeqs[historyKey] = max(0, nextBackfillAfterSeq - Int64(pageLimit))
        historyMessages[conversationID] = message
    }

    func markOlderHistoryApplied(historyKey: String, conversationID: String) {
        historyBackfillAfterSeqs.removeValue(forKey: historyKey)
        historyReachedStartKeys.remove(historyKey)
        historyMessages[conversationID] = nil
        directDisabledMessages[conversationID] = nil
        directFriendRequestContexts[conversationID] = nil
    }

    func reset() {
        conversations = []
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
    }
}

struct ConversationSelectionEpochFence {
    typealias Token = ConversationStore.ConversationSelectionRequestToken

    private(set) var epoch: UInt64 = 0
    private(set) var activeScope = ""
    private(set) var activeConversationID = ""

    mutating func select(scope: String, conversationID: String) -> Token {
        epoch &+= 1
        activeScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        activeConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Token(scope: activeScope, conversationID: activeConversationID, epoch: epoch)
    }

    mutating func leave(scope: String, conversationID: String) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeScope == normalizedScope,
              activeConversationID == normalizedConversationID else { return }
        invalidate()
    }

    mutating func invalidate() {
        epoch &+= 1
        activeScope = ""
        activeConversationID = ""
    }

    func token(scope: String, conversationID: String) -> Token? {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty,
              !normalizedConversationID.isEmpty,
              activeScope == normalizedScope,
              activeConversationID == normalizedConversationID else { return nil }
        return Token(scope: activeScope, conversationID: activeConversationID, epoch: epoch)
    }

    func accepts(_ token: Token) -> Bool {
        token.epoch == epoch
            && token.scope == activeScope
            && token.conversationID == activeConversationID
    }
}

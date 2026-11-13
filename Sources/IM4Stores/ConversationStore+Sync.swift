import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN

public extension ConversationStore {
    public struct ReadAckSyncClaim: Equatable, Sendable {
        public let command: ReadAckCommand
        fileprivate let generation: UInt64
    }

    func isMessageSyncInFlight(historyKey: String) -> Bool {
        messageSyncEngine.isInFlight(messageSyncRequest(historyKey: historyKey, reason: "status"))
    }

    func conversationPollingPlan(
        conversationID: String,
        shouldPollActiveConversation: Bool,
        historyKeyForConversation: (ConversationMessageSnapshot) -> String
    ) -> ConversationPollingPlan {
        guard let conversation = conversationMessageSnapshot(id: conversationID) else {
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

    // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110_BEGIN
    public struct HistorySyncClaim: Equatable, Sendable {
        fileprivate let request: SyncEngineRequest
        fileprivate let conversationID: String
        fileprivate let showsLoading: Bool
        fileprivate let identity = UUID()
    }

    func beginHistorySyncClaim(request: SyncEngineRequest, conversationID: String, showLoadingIndicator: Bool) -> HistorySyncClaim? {
        guard messageSyncEngine.begin(request).started else { return nil }
        let claim = HistorySyncClaim(request: request, conversationID: conversationID, showsLoading: showLoadingIndicator)
        activeHistorySyncClaims[request.inFlightKey] = claim
        return claim
    }

    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
    func isCurrentHistorySyncClaim(_ claim: HistorySyncClaim) -> Bool {
        activeHistorySyncClaims[claim.request.inFlightKey] == claim
    }
    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END

    func finishHistorySync(_ claim: HistorySyncClaim) {
        guard isCurrentHistorySyncClaim(claim) else { return } // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111
        activeHistorySyncClaims.removeValue(forKey: claim.request.inFlightKey)
        messageSyncEngine.finish(claim.request)
        if claim.showsLoading,
           !activeHistorySyncClaims.values.contains(where: { $0.conversationID == claim.conversationID && $0.showsLoading }) {
            historyLoadingIDs.remove(claim.conversationID)
        }
    }

    func beginMessageSync(historyKey: String, conversationID: String, showLoadingIndicator: Bool) -> Bool {
        beginMessageSyncClaim(historyKey: historyKey, conversationID: conversationID, showLoadingIndicator: showLoadingIndicator) != nil
    }

    func beginMessageSyncClaim(historyKey: String, conversationID: String, showLoadingIndicator: Bool) -> HistorySyncClaim? {
        let request = messageSyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "begin")
        guard let claim = beginHistorySyncClaim(request: request, conversationID: conversationID, showLoadingIndicator: showLoadingIndicator) else {
            if showLoadingIndicator {
                historyMessages[conversationID] = nil
            }
            return nil
        }
        if showLoadingIndicator {
            historyMessages[conversationID] = nil
            historyLoadingIDs.insert(conversationID)
        }
        return claim
    }

    func finishMessageSync(historyKey: String, conversationID: String, showLoadingIndicator: Bool) {
        let request = messageSyncRequest(historyKey: historyKey, conversationID: conversationID, reason: "finish")
        guard let claim = activeHistorySyncClaims[request.inFlightKey] else { return }
        finishHistorySync(claim)
    }
    // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110_END

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
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> ReadReceiptSidecarSyncTarget? {
        // Delivery receipts remain a baseline capability when detailed read
        // identities/counts are licensed off, matching history backfill.
        _ = readReceiptsEnabled
        let target = ReadReceiptSidecarSyncTarget(channelID: channelID, channelType: channelType)
        guard !target.channelID.isEmpty else { return nil }
        let hasOutgoingMessages = conversationMessageSnapshots()
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

    func olderHistorySyncRequest(historyKey: String, conversationID: String, reason: String) -> SyncEngineRequest {
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

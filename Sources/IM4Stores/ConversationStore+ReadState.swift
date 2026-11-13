import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN

public extension ConversationStore {
    func pendingDirectReadWindow(
        channelID: String,
        senderIdentities: Set<String>,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> PendingDirectReadWindow? {
        guard let conversation = conversationMessageSnapshots().first(where: {
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
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard readReceiptsEnabled, watermark > 0,
                  let index = conversationMessageSnapshots().firstIndex(where: { $0.id == window.conversationID && $0.kind == .direct }) else { return false }
            var conversation = conversationMessageSnapshot(at: index)
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
            commitConversationSnapshot(conversation, at: index)
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func clearUnread(conversationID: String, includeSystemConversations: Bool) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            for index in next.indices where next[index].id == conversationID || (includeSystemConversations && next[index].kind == .system) {
                let readSeq = latestReadableSequence(in: next[index])
                Self.clearUnreadFields(in: &next[index], through: readSeq)
                changedIndices.insert(index)
            }
            if !changedIndices.isEmpty { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            // WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_END
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private static func clearUnreadFields(in conversation: inout ConversationMessageSnapshot, through readSeq: Int64) {
        conversation.lastReadSeq = max(conversation.lastReadSeq, readSeq)
        conversation.unread = 0
        conversation.hasUnreadReaction = false
        conversation.unreadReactionCount = 0
        conversation.firstUnreadSeq = 0
        conversation.firstUnreadMessageID = ""
        conversation.unreadAnchorSeq = 0
        conversation.unreadAnchorState = "none"
    }

    func clearUnread(conversationID: String, isSystemConversationID: (String) -> Bool) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let key = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            let targetIsSystem = conversationMessageSnapshots().first(where: { $0.id == key })?.kind == .system
                || isSystemConversationID(key)
            clearUnread(conversationID: key, includeSystemConversations: targetIsSystem)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func advanceRead(conversationID: String, through confirmedSeq: Int64) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard confirmedSeq > 0,
                  let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            var conversation = conversationMessageSnapshot(at: index)
            if advanceRead(in: &conversation, through: confirmedSeq) {
                commitConversationSnapshot(conversation, at: index)
            }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func advanceRead(in conversation: inout ConversationMessageSnapshot, through confirmedSeq: Int64, restoringConfirmedRead: Bool = false) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            // The readable prefix may stop at a coverage gap before the known tail.
            let knownTailSeq = max(
                conversation.lastMsgSeq,
                // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：避免已读推进时生成序号临时数组
                ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
                // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            )
            let readableSeq = latestReadableSequence(in: conversation)
            // A persisted server ACK can cover the cached tail even when its messages aren't loaded.
            let latestSeq = restoringConfirmedRead && confirmedSeq >= knownTailSeq
                ? max(readableSeq, knownTailSeq)
                : readableSeq
            let boundedSeq = min(confirmedSeq, latestSeq)
            let previousReadSeq = conversation.lastReadSeq
            // WDT_CHAT_UNREAD_BADGE_20261021_BEGIN: an idempotent tail ACK may still need to reconcile a stale badge.
            guard boundedSeq > 0, boundedSeq >= previousReadSeq else { return false }
            guard boundedSeq < max(latestSeq, knownTailSeq) else {
                let current = conversation
                // A repeated message ACK is not proof that newly arrived reactions were read.
                guard boundedSeq > previousReadSeq
                    || (!current.hasUnreadReaction && current.unreadReactionCount == 0) else { return false }
                guard boundedSeq > previousReadSeq
                    || current.unread != 0
                    || current.hasUnreadReaction
                    || current.unreadReactionCount != 0
                    || current.firstUnreadSeq != 0
                    || !current.firstUnreadMessageID.isEmpty
                    || current.unreadAnchorSeq != 0
                    || current.unreadAnchorState != "none" else { return false }
                Self.clearUnreadFields(in: &conversation, through: latestSeq)
                return true
            }
            guard boundedSeq > previousReadSeq else { return false }
            conversation.lastReadSeq = boundedSeq
            // WDT_CHAT_UNREAD_BADGE_20261021_END

            let previousUnread = conversation.unread
            let acknowledgedIncomingCount = conversation.messages.filter { message in
                !message.isOutgoing
                    && message.channelSeq > previousReadSeq
                    && message.channelSeq <= boundedSeq
            }.count
            let remainingIncoming = conversation.messages
                .filter { !$0.isOutgoing && $0.channelSeq > boundedSeq }
                .sorted { $0.channelSeq < $1.channelSeq }
            let unresolvedReactionMinimum = conversation.hasUnreadReaction
                || conversation.unreadReactionCount > 0
                ? max(1, conversation.unreadReactionCount)
                : 0
            conversation.unread = max(
                unresolvedReactionMinimum,
                max(remainingIncoming.count, max(0, previousUnread - acknowledgedIncomingCount))
            )
            if let firstUnread = remainingIncoming.first {
                if conversation.firstUnreadSeq <= boundedSeq
                    || conversation.firstUnreadSeq >= firstUnread.channelSeq {
                    conversation.firstUnreadSeq = firstUnread.channelSeq
                    conversation.firstUnreadMessageID = firstUnread.id
                }
                if conversation.unreadAnchorSeq <= boundedSeq {
                    conversation.unreadAnchorSeq = conversation.firstUnreadSeq
                }
            } else if conversation.firstUnreadSeq <= boundedSeq {
                conversation.firstUnreadSeq = 0
                conversation.firstUnreadMessageID = ""
                if conversation.unreadAnchorSeq <= boundedSeq {
                    conversation.unreadAnchorSeq = 0
                }
            }
            if conversation.unread == 0 {
                conversation.unreadAnchorState = "none"
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
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

    func isLocallyReadThrough(key: String, lastMessageSeq: Int64) -> Bool {
        guard lastMessageSeq > 0 else { return false }
        return locallyReadSeq(forKey: key) >= lastMessageSeq
    }

    func applyRemoteReadSummary(
        from remote: RemoteMessage,
        to message: inout ChatMessage,
        readReceiptsEnabled: Bool
    ) {
        guard message.isOutgoing, message.status != .recalled, !message.isDeletedLocally else { return }
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
        toMessagesIn conversation: inout ConversationMessageSnapshot,
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
        makeReadReceipt: (RemoteMessageReceipt, ConversationMessageSnapshot) -> ReadReceipt,
        makeUnreadReceipt: (RemoteMessageReadParticipant, ConversationMessageSnapshot) -> ReadReceipt,
        makeReactionDetail: (RemoteMessageReactionReceipt) -> ReactionDetail,
        preserveSyncedReactions: Bool = false
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }),
                  conversationMessageSnapshot(at: cIndex).messages[mIndex].isOutgoing else { return false }
            let conversation = conversationMessageSnapshot(at: cIndex)
            let previous = conversation.messages[mIndex]
            guard previous.status != .recalled, !previous.isDeletedLocally else { return false }
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
            // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023
            let canViewDetails = response.canViewDetails
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
            // WDT_RECEIPT_DETAIL_SCOPE_20261023: a late personnel response must not resurrect removed reactions.
            if !preserveSyncedReactions {
                let reactionDetails = response.reactions.map { makeReactionDetail($0) }
                updated.reactionDetails = reactionDetails.isEmpty ? previous.reactionDetails : reactionDetails
            }
            updated.readStateKnown = true
            updated.canViewReadDetails = canViewDetails
            if isRead {
                updated.status = .read
            } else if updated.status == .read {
                updated.status = .sent
            }
            guard updated != previous else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0 = updated } // WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func inferredUnreadCount(response: RemoteMessageReadReceiptResponse, conversation: ConversationMessageSnapshot, readCount: Int) -> Int? {
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
        conversation: ConversationMessageSnapshot,
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
        channelIDForConversation: (ConversationMessageSnapshot) -> String,
        makeReadReceipt: (RemoteMessageReceipt, ConversationMessageSnapshot) -> ReadReceipt
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard !receipts.isEmpty,
                  let cIndex = conversationMessageSnapshots().firstIndex(where: { $0.id == channelID || channelIDForConversation($0) == channelID }) else { return false }
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

            var conversation = conversationMessageSnapshot(at: cIndex)
            var didChange = false
            for mIndex in conversation.messages.indices {
                let originalMessage = conversation.messages[mIndex]
                guard originalMessage.isOutgoing,
                      originalMessage.status != .recalled, !originalMessage.isDeletedLocally else { continue }

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
                // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023: a late receipt must not reopen explicitly hidden details.
                if !message.canViewReadDetails {
                    message.readBy = []
                    message.unreadBy = []
                    message.readCount = nil
                    message.unreadCount = nil
                } else if detailedItems.isEmpty {
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
            commitConversationSnapshot(conversation, at: cIndex)
            return true
            // JHT_MOD_END CHAT_READ_RECEIPT_APPLY_INDEX_PERF_20260912 - 修改结束
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023_BEGIN
    @discardableResult
    func updateReadReceiptDetailsVisibility(_ allowed: Bool, conversationID: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
            var conversation = conversationMessageSnapshot(at: index)
            for messageIndex in conversation.messages.indices {
                conversation.messages[messageIndex].canViewReadDetails = allowed
                if !allowed {
                    conversation.messages[messageIndex].readBy = []
                    conversation.messages[messageIndex].unreadBy = []
                    conversation.messages[messageIndex].readCount = nil
                    conversation.messages[messageIndex].unreadCount = nil
                }
            }
            guard conversation != conversationMessageSnapshot(at: index) else { return false }
            commitConversationSnapshot(conversation, at: index)
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }
    // WDT_CHAT_FIX1_RECEIPT_PRIVACY_20261023_END

    @discardableResult
    func stripReadReceiptDetailsFromAllMessages() -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            var next = conversationMessageSnapshots()
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
                commitConversationSnapshots(next, unreadUpdate: .preserve)
            }
            return didChange
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

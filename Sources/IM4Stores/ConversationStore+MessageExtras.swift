import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN

// WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_BEGIN

// WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110_BEGIN
public extension ConversationStore {
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
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedEmoji = extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedAction = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !extra.messageID.isEmpty, !normalizedEmoji.isEmpty else { return false }
            for cIndex in conversations.indices {
                guard let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == extra.messageID }) else { continue }
                var message = conversationMessageSnapshot(at: cIndex).messages[mIndex]
                let detailID = reactionDetailID(messageID: extra.messageID, operatorUID: extra.operatorUID, emoji: normalizedEmoji)
                let isMine = currentUserIDs.contains(extra.operatorUID)
                let reactionIndex = message.reactions.firstIndex { $0.emoji == normalizedEmoji }
                let hasOperatorDetail = message.reactionDetails.contains { $0.id == detailID }
                if normalizedAction == "remove" {
                    let hasOwnReaction = reactionIndex.map { message.reactions[$0].reactedByMe } ?? false
                    guard hasOperatorDetail || (isMine && hasOwnReaction) else { return false }
                    if let reactionIndex {
                        if hasOperatorDetail || (isMine && hasOwnReaction) {
                            message.reactions[reactionIndex].count = max(0, message.reactions[reactionIndex].count - 1)
                        }
                        if isMine { message.reactions[reactionIndex].reactedByMe = false }
                        if message.reactions[reactionIndex].count == 0 { message.reactions.remove(at: reactionIndex) }
                    }
                    message.reactionDetails.removeAll { $0.id == detailID }
                    mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0 = message }
                    return true
                }
                var didChange = false
                if let reactionIndex {
                    if isMine, !message.reactions[reactionIndex].reactedByMe {
                        message.reactions[reactionIndex].reactedByMe = true
                        didChange = true
                    }
                } else {
                    message.reactions.append(Reaction(id: "\(extra.messageID)_\(normalizedEmoji)", emoji: normalizedEmoji, count: 1, reactedByMe: isMine))
                    didChange = true
                }
                if !hasOperatorDetail {
                    // Mapping may read the Store; it observes the previous complete commit.
                    message.reactionDetails.append(makeReactionDetail(extra, detailID))
                    didChange = true
                }
                if didChange { mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0 = message } }
                return didChange
            }
            return false
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    // JHT_MOD_BEGIN MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改开始：同步回来的 reaction extras 批量应用，避免每条 extra 多次全表扫描和多次发布
    public struct SyncedReactionExtrasApplyResult: Sendable {
        public let processed: Int
        public let changed: Int
        public let conversationsChanged: Int
        public let messagesChanged: Int
        public let skipped: [RemoteMessageExtra]

        public static let empty = SyncedReactionExtrasApplyResult(
            processed: 0,
            changed: 0,
            conversationsChanged: 0,
            messagesChanged: 0,
            skipped: []
        )

        public init(processed: Int, changed: Int, conversationsChanged: Int, messagesChanged: Int, skipped: [RemoteMessageExtra]) {
            self.processed = processed
            self.changed = changed
            self.conversationsChanged = conversationsChanged
            self.messagesChanged = messagesChanged
            self.skipped = skipped
        }
    }

    @discardableResult
    func applySyncedReactionExtras(
        _ extras: [RemoteMessageExtra],
        currentUserIDs: Set<String>,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> SyncedReactionExtrasApplyResult {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
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

            let unreadRevision = memorySnapshot.revision
            var updatedConversations = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
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
                changedIndices.insert(cIndex)
            }

            if conversationsChanged > 0 {
                commitConversationChanges(in: updatedConversations, at: changedIndices, preparedAt: unreadRevision)
            }
            return SyncedReactionExtrasApplyResult(
                processed: reactionExtras.count,
                changed: changedExtras,
                conversationsChanged: conversationsChanged,
                messagesChanged: messagesChanged,
                skipped: skipped
            )
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func applySyncedReactionExtra(
        _ extra: RemoteMessageExtra,
        to message: inout ChatMessage,
        isDuplicate: Bool,
        currentUserIDs: Set<String>,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> Bool {
        let normalizedEmoji = extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.messageID.isEmpty, !normalizedEmoji.isEmpty,
              message.status != .recalled, !message.isDeletedLocally else { return false }
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

    @discardableResult
    func applyRemoteEditExtra(
        _ extra: RemoteMessageExtra,
        normalizedChannelID: String,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let messageID = extra.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let editedText = editedText(from: extra.payload)
            let incomingRevision = extra.editRevision
            guard !messageID.isEmpty, !editedText.isEmpty, incomingRevision > 0 else { return false }
            var didApply = false
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            for cIndex in next.indices {
                let conversationChannelID = channelIDForConversation(next[cIndex])
                guard normalizedChannelID.isEmpty
                        || conversationChannelID == normalizedChannelID
                        || next[cIndex].id == normalizedChannelID else { continue }
                let messageIndex = next[cIndex].messages.firstIndex { message in
                    message.id == messageID || (extra.channelSeq > 0 && message.channelSeq == extra.channelSeq)
                }
                guard let mIndex = messageIndex else { continue }
                let current = next[cIndex].messages[mIndex]
                let normalizedContentType = current.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard current.kind == .text,
                      normalizedContentType.isEmpty || ["text", "plain_text", "text/plain"].contains(normalizedContentType),
                      current.status != .recalled,
                      !current.isDeletedLocally,
                      incomingRevision > current.editRevision else { continue }
                next[cIndex].messages[mIndex].text = editedText
                next[cIndex].messages[mIndex].isEdited = true
                next[cIndex].messages[mIndex].editRevision = incomingRevision
                updateConversationLatestFromMessages(&next[cIndex])
                didApply = true
                changedIndices.insert(cIndex)
            }
            if didApply { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            return didApply
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func applyRemotePinExtra(
        _ extra: RemoteMessageExtra,
        normalizedChannelID: String,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard !extra.messageID.isEmpty else { return false }
            let action = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isPinned = extra.payload["pinned"]?.boolValue ?? ["pin", "pinned", "true", "1"].contains(action)
            var didApply = false
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            for cIndex in next.indices {
                let conversationChannelID = channelIDForConversation(next[cIndex])
                guard normalizedChannelID.isEmpty
                        || conversationChannelID == normalizedChannelID
                        || next[cIndex].id == normalizedChannelID else { continue }
                if let mIndex = next[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }) {
                    next[cIndex].messages[mIndex].isPinned = isPinned
                    didApply = true
                changedIndices.insert(cIndex)
                }
            }
            if didApply { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            return didApply
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
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

    // One remote event owns count/detail/read/reminder publication, while optimistic
    // local actions continue using the individual operations below.
    @discardableResult
    func applyReactionExtra(
        _ extra: RemoteMessageExtra,
        currentUserIDs: Set<String>,
        activeConversationID: String?,
        includeReminder: Bool,
        channelIDForConversation: (ConversationMessageSnapshot) -> String,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            let reaction = applyMessageReaction(
                messageID: extra.messageID, emoji: extra.emoji, operatorUID: extra.operatorUID,
                action: extra.action, currentUserIDs: currentUserIDs, in: &next, changedIndices: &changedIndices
            )
            let detail = applyMessageReactionDetail(extra, in: &next, changedIndices: &changedIndices, makeReactionDetail: makeReactionDetail)
            let didUpdateRead = applyReactionReadStateIfNeeded(extra, currentUserIDs: currentUserIDs, in: &next, changedIndices: &changedIndices)
            let didMarkReminder = includeReminder && markReactionReminderIfNeeded(
                extra, currentUserIDs: currentUserIDs, activeConversationID: activeConversationID,
                in: &next, changedIndices: &changedIndices, channelIDForConversation: channelIDForConversation
            )
            if reaction.didWrite || detail.didWrite || didUpdateRead || didMarkReminder { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            return detail.applied
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func markReactionReminderIfNeeded(
        _ extra: RemoteMessageExtra,
        currentUserIDs: Set<String>,
        activeConversationID: String?,
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            if markReactionReminderIfNeeded(extra, currentUserIDs: currentUserIDs,
                activeConversationID: activeConversationID, in: &next, changedIndices: &changedIndices, channelIDForConversation: channelIDForConversation) {
                commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision)
            }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func markReactionReminderIfNeeded(
        _ extra: RemoteMessageExtra, currentUserIDs: Set<String>, activeConversationID: String?,
        in values: inout [ConversationMessageSnapshot], changedIndices: inout Set<Int>, channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "remove" else { return false }
            let operatorUID = extra.operatorUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !operatorUID.isEmpty, !currentUserIDs.contains(operatorUID) else { return false }
            guard let index = values.firstIndex(where: { conversation in
                conversation.messages.contains(where: { $0.id == extra.messageID })
                    || conversation.id == extra.channelID || channelIDForConversation(conversation) == extra.channelID
            }) else { return false }
            values[index].hasUnreadReaction = true
            if activeConversationID != values[index].id {
                values[index].unread += 1
                values[index].unreadReactionCount += 1
            }
            changedIndices.insert(index)
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func applyMessageReaction(
        messageID: String, emoji: String, operatorUID: String, action: String, currentUserIDs: Set<String>
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            let result = applyMessageReaction(messageID: messageID, emoji: emoji, operatorUID: operatorUID,
                action: action, currentUserIDs: currentUserIDs, in: &next, changedIndices: &changedIndices)
            if result.didWrite { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            return result.applied
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func applyMessageReaction(
        messageID: String, emoji: String, operatorUID: String, action: String, currentUserIDs: Set<String>,
        in values: inout [ConversationMessageSnapshot], changedIndices: inout Set<Int>
    ) -> (applied: Bool, didWrite: Bool) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !messageID.isEmpty, !normalizedEmoji.isEmpty else { return (false, false) }
            let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isMine = currentUserIDs.contains(operatorUID)
            for cIndex in values.indices {
                guard let mIndex = values[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { continue }
                var message = values[cIndex].messages[mIndex]
                var didWrite = false
                if let rIndex = message.reactions.firstIndex(where: { $0.emoji == normalizedEmoji }) {
                    if normalizedAction == "remove" {
                        let shouldDecrement = !isMine || message.reactions[rIndex].reactedByMe
                        if shouldDecrement {
                            message.reactions[rIndex].count = max(0, message.reactions[rIndex].count - 1)
                            didWrite = true
                        }
                        if isMine {
                            message.reactions[rIndex].reactedByMe = false
                            didWrite = true
                        }
                        if message.reactions[rIndex].count == 0 {
                            message.reactions.remove(at: rIndex)
                            didWrite = true
                        }
                    } else {
                        if !(isMine && message.reactions[rIndex].reactedByMe) {
                            message.reactions[rIndex].count += 1
                            didWrite = true
                        }
                        if isMine {
                            message.reactions[rIndex].reactedByMe = true
                            didWrite = true
                        }
                    }
                } else if normalizedAction != "remove" {
                    message.reactions.append(Reaction(id: "\(messageID)_\(normalizedEmoji)", emoji: normalizedEmoji, count: 1, reactedByMe: isMine))
                    didWrite = true
                }
                if didWrite { values[cIndex].messages[mIndex] = message; changedIndices.insert(cIndex) }
                return (true, didWrite)
            }
            return (false, false)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func applyMessageReactionDetail(
        _ extra: RemoteMessageExtra, makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            let result = applyMessageReactionDetail(extra, in: &next, changedIndices: &changedIndices, makeReactionDetail: makeReactionDetail)
            if result.didWrite { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            return result.applied
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func applyMessageReactionDetail(
        _ extra: RemoteMessageExtra, in values: inout [ConversationMessageSnapshot], changedIndices: inout Set<Int>,
        makeReactionDetail: (RemoteMessageExtra, String) -> ReactionDetail
    ) -> (applied: Bool, didWrite: Bool) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedEmoji = extra.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extra.messageID.isEmpty, !normalizedEmoji.isEmpty else { return (false, false) }
            let normalizedAction = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for cIndex in values.indices {
                guard let mIndex = values[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }) else { continue }
                let detailID = reactionDetailID(messageID: extra.messageID, operatorUID: extra.operatorUID, emoji: normalizedEmoji)
                if normalizedAction == "remove" {
                    values[cIndex].messages[mIndex].reactionDetails.removeAll { $0.id == detailID }
                } else if !values[cIndex].messages[mIndex].reactionDetails.contains(where: { $0.id == detailID }) {
                    let detail = makeReactionDetail(extra, detailID)
                    values[cIndex].messages[mIndex].reactionDetails.append(detail)
                } else {
                    return (true, false)
                }
                changedIndices.insert(cIndex)
                return (true, true)
            }
            return (false, false)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func applyReactionReadStateIfNeeded(_ extra: RemoteMessageExtra, currentUserIDs: Set<String>) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            if applyReactionReadStateIfNeeded(extra, currentUserIDs: currentUserIDs, in: &next, changedIndices: &changedIndices) { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func applyReactionReadStateIfNeeded(
        _ extra: RemoteMessageExtra, currentUserIDs: Set<String>, in values: inout [ConversationMessageSnapshot], changedIndices: inout Set<Int>
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let operatorUID = extra.operatorUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !operatorUID.isEmpty, !currentUserIDs.contains(operatorUID),
                  extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "remove" else { return false }
            for cIndex in values.indices {
                guard let mIndex = values[cIndex].messages.firstIndex(where: { $0.id == extra.messageID }),
                      values[cIndex].messages[mIndex].isOutgoing,
                      values[cIndex].messages[mIndex].status != .recalled,
                      !values[cIndex].messages[mIndex].isDeletedLocally else { continue }
                values[cIndex].messages[mIndex].status = .read
                values[cIndex].messages[mIndex].readStateKnown = true
                if values[cIndex].messages[mIndex].readCount == nil {
                    values[cIndex].messages[mIndex].readCount = 1
                } else {
                    values[cIndex].messages[mIndex].readCount = max(values[cIndex].messages[mIndex].readCount ?? 0, 1)
                }
                changedIndices.insert(cIndex)
                return true
            }
            return false
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    private func reactionDetailID(messageID: String, operatorUID: String, emoji: String) -> String {
        [messageID, operatorUID, emoji]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

}
// WDT_IOS1_REFACTOR_MESSAGE_SIDECAR_HISTORY_BOUNDARY_20261110_END
// WDT_IOS1_REFACTOR_SIDECAR_PAGE_ATOMIC_COMMIT_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

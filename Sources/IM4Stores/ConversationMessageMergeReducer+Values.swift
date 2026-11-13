// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
import Foundation
import IM4Domain
import IM4Data

extension ConversationMessageMergeReducer {
    func conversationMessageSnapshots() -> [ConversationMessageSnapshot] { conversations }

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

    func defaultRecallText(for message: ChatMessage) -> String {
        if message.isOutgoing {
            return "你撤回了一条消息"
        }
        let sender = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, sender != "未知用户", sender != "系统" else {
            return "对方撤回了一条消息"
        }
        return "\(sender)撤回了一条消息"
    }

    func inferredMessageSequenceCoverage(_ messages: [ChatMessage]) -> Int64 {
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

    func isPendingLocalMessage(_ message: ChatMessage) -> Bool {
        message.id.hasPrefix("local_") || message.status == .sending || message.status == .failed
    }

    func latestConfirmedMessage(in messages: [ChatMessage]) -> ChatMessage? {
        messages.last { message in
            message.status != .failed && message.status != .sending && !message.isDeletedLocally
        }
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

    func markMessageAsRecalled(_ message: inout ChatMessage, recallText: String?) {
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

    func mergeExistingRemoteState(from previous: ChatMessage, into message: inout ChatMessage) {
        // History and sidecars are fetched independently. A stale body or read
        // state cannot undo a recall or deletion that has already been applied.
        if previous.isDeletedLocally, !message.isDeletedLocally {
            markMessageAsAdminDeleted(&message)
        } else if previous.status == .recalled, message.status != .recalled {
            markMessageAsRecalled(&message, recallText: nil)
        }
        guard message.status != .recalled, !message.isDeletedLocally else { return }
        // WDT_CHAT_MEDIA_CACHE_REUSE_20261102: history payloads can omit file-detail cache metadata.
        if let fileID = previous.attachmentFileID, !fileID.isEmpty,
           message.attachmentFileID == fileID, message.kind == previous.kind,
           !previous.isDeletedLocally, !message.isDeletedLocally,
           previous.status != .recalled, message.status != .recalled,
           (message.attachmentVersion.isEmpty || previous.attachmentVersion.isEmpty || message.attachmentVersion == previous.attachmentVersion),
           (message.attachmentChecksum.isEmpty || previous.attachmentChecksum.isEmpty || message.attachmentChecksum == previous.attachmentChecksum),
           (message.attachmentSizeBytes == nil || previous.attachmentSizeBytes == nil || message.attachmentSizeBytes == previous.attachmentSizeBytes) {
            if message.attachmentCacheKey.isEmpty { message.attachmentCacheKey = previous.attachmentCacheKey }
            if message.attachmentVersion.isEmpty { message.attachmentVersion = previous.attachmentVersion }
            if message.attachmentChecksum.isEmpty { message.attachmentChecksum = previous.attachmentChecksum }
            if message.attachmentMimeType.isEmpty { message.attachmentMimeType = previous.attachmentMimeType }
            if message.attachmentExtension.isEmpty { message.attachmentExtension = previous.attachmentExtension }
            if message.attachmentSizeBytes == nil { message.attachmentSizeBytes = previous.attachmentSizeBytes }
        }
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

    func messageSequenceCoveredThrough(in conversation: ConversationMessageSnapshot) -> Int64 {
        let explicitCoverage = max(0, conversation.messageCoveredThroughSeq)
        if conversation.messageCoverageRequiresRecovery {
            return explicitCoverage
        }
        return max(explicitCoverage, inferredMessageSequenceCoverage(conversation.messages))
    }

    func messageTimelinePrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.channelSeq > 0, rhs.channelSeq > 0, lhs.channelSeq != rhs.channelSeq {
            return lhs.channelSeq < rhs.channelSeq
        }
        let lhsDate = lhs.createdAt ?? Date.distantPast
        let rhsDate = rhs.createdAt ?? Date.distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }

    func retainedMessages(_ messages: [ChatMessage], for retention: MessageWindowRetention) -> [ChatMessage] {
        IM4Stores.retainedConversationMessages(messages, for: retention)
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

    func unavailableReplyContext(messageID: String = "") -> MessageReplyContext {
        MessageReplyContext(
            messageID: messageID,
            summary: "原消息不可查看/已撤回",
            isUnavailable: true
        )
    }

}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END

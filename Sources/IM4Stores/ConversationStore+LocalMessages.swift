import IM4Domain
import IM4Data
import Foundation // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_INCREMENTAL_UNREAD_20261110_BEGIN

// WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_BEGIN
// WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110_BEGIN
public extension ConversationStore {
    // Reduce a value snapshot, then publish the message window and metadata together.
    func mutateStoredConversation(at index: Int, _ change: (inout ConversationMessageSnapshot) -> Void) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            var updated = conversationMessageSnapshot(at: index)
            change(&updated)
            commitConversationSnapshot(updated, at: index)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func mutateStoredMessage(
        at messageIndex: Int,
        inConversationAt conversationIndex: Int,
        _ change: (inout ChatMessage) -> Void
    ) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            mutateStoredConversation(at: conversationIndex) { change(&$0.messages[messageIndex]) }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func mutateStoredMessageWindow(
        inConversationAt conversationIndex: Int,
        _ change: (inout [ChatMessage]) -> Void
    ) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            mutateStoredConversation(at: conversationIndex) { change(&$0.messages) }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }


    func latestConfirmedMessage(in messages: [ChatMessage]) -> ChatMessage? {
        messages.last { message in
            message.status != .failed && message.status != .sending && !message.isDeletedLocally
        }
    }

    func updateConversationLatestFromMessages(at index: Int) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard conversations.indices.contains(index) else { return }
            var updated = conversationMessageSnapshot(at: index)
            guard updateConversationLatestFromMessages(&updated) else { return }
            commitConversationSnapshot(updated, at: index)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func updateConversationLatestFromMessages(_ conversation: inout ConversationMessageSnapshot) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let latest = latestConfirmedMessage(in: conversation.messages) else { return false }
            conversation.lastMessage = conversationListPreview(latest)
            conversation.time = latest.time
            conversation.sortTimestamp = max(conversation.sortTimestamp, effectiveCreatedAt(for: latest)?.timeIntervalSince1970 ?? 0)
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func appendLocalOutgoingMessage(
        _ message: ChatMessage,
        to conversationID: String,
        preview: String? = nil,
        displayTime: String = "刚刚"
    ) -> ConversationMessageSnapshot? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedConversationID.isEmpty,
                  let index = conversations.firstIndex(where: { $0.id == normalizedConversationID }) else { return nil }
            mutateStoredConversation(at: index) { conversation in
                conversation.messages.append(message)
                conversation.lastMessage = message.conversationAttachmentPreview ?? preview ?? conversationListPreview(message)
                conversation.time = displayTime
                conversation.sortTimestamp = effectiveCreatedAt(for: message)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            }
            return conversationMessageSnapshot(at: index)
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func applyLocalMessageEdit(messageID: String, conversationID: String, text: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  !trimmedText.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredConversation(at: cIndex) { conversation in
                conversation.messages[mIndex].text = trimmedText
                conversation.messages[mIndex].isEdited = true
                conversation.messages[mIndex].status = .sent
                conversation.lastMessage = trimmedText
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func markAttachmentUploadFailed(
        messageID: String,
        conversationID: String,
        failureStatus: String = "failed",
        failure: AttachmentUploadFailure? = nil
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            let normalizedFailureStatus = failureStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) {
                $0.status = .failed
                $0.attachmentUploadStatus = normalizedFailureStatus.isEmpty ? "failed" : normalizedFailureStatus
                $0.attachmentUploadFailure = failure
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func updateAttachmentUploadStatus(
        _ status: String,
        messageID: String,
        conversationID: String
    ) -> ChatMessage? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  !normalizedStatus.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) {
                $0.attachmentUploadStatus = normalizedStatus
                $0.attachmentUploadFailure = nil
            }
            return conversationMessageSnapshot(at: cIndex).messages[mIndex]
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func markAttachmentUploadRetrying(messageID: String, conversationID: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) {
                $0.status = .sending
                // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_RETRY - 修改开始：重试阶段只更新状态，不写假百分比
                $0.attachmentTransferProgress = nil
                // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_RETRY - 修改结束
                $0.attachmentUploadStatus = "retrying"
                $0.attachmentUploadFailure = nil
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func messagePinnedState(messageID: String, conversationID: String) -> Bool? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        return conversationMessageSnapshot(at: cIndex).messages[mIndex].isPinned
    }

    @discardableResult
    func setMessagePinned(messageID: String, conversationID: String, pinned: Bool) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.isPinned = pinned }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func messageFavoritedState(messageID: String, conversationID: String) -> Bool? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedConversationID.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
              let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
        return conversationMessageSnapshot(at: cIndex).messages[mIndex].isFavorited
    }

    @discardableResult
    func setMessageFavorited(messageID: String, conversationID: String, favorited: Bool) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.isFavorited = favorited }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func setMessageReportState(messageID: String, conversationID: String, reason: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.reportState = reason }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func markMessageResendFailed(messageID: String, conversationID: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.status = .failed }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func markMessageFailed(messageID: String, conversationID: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredConversation(at: cIndex) { conversation in
                conversation.messages[mIndex].status = .failed
                updateConversationLatestFromMessages(&conversation)
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func removeMessage(messageID: String, conversationID: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }) else { return false }
            guard let removed = conversationMessageSnapshot(at: cIndex).messages.first(where: { $0.id == normalizedMessageID }) else { return false }
            mutateStoredConversation(at: cIndex) { conversation in
                conversation.messages.removeAll { $0.id == normalizedMessageID }
                if latestConfirmedMessage(in: conversation.messages) != nil {
                    updateConversationLatestFromMessages(&conversation)
                } else if conversation.lastMsgSeq == 0 || conversation.lastMessage == conversationListPreview(removed) {
                    conversation.lastMessage = ""
                    conversation.time = ""
                }
            }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func setAttachmentFileID(_ fileID: String, messageID: String, conversationID: String) -> ChatMessage? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedFileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedFileID.isEmpty,
                  !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.attachmentFileID = normalizedFileID }
            return conversationMessageSnapshot(at: cIndex).messages[mIndex]
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func updateMessageAttachment(_ message: ChatMessage, conversationID: String) -> ChatMessage? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == message.id }) else { return nil }
            var conversation = conversationMessageSnapshot(at: cIndex)
            let previous = conversation.messages[mIndex]
            var updated = previous
            updated.attachmentName = message.attachmentName
            updated.attachmentMeta = message.attachmentMeta
            updated.attachmentFileID = message.attachmentFileID
            updated.attachmentSizeBytes = message.attachmentSizeBytes
            updated.attachmentPreviewURL = message.attachmentPreviewURL
            updated.attachmentDownloadURL = message.attachmentDownloadURL
            updated.attachmentPreviewAvailable = message.attachmentPreviewAvailable
            updated.attachmentDownloadAvailable = message.attachmentDownloadAvailable
            updated.attachmentTransferProgress = message.attachmentTransferProgress
            updated.attachmentMimeType = message.attachmentMimeType
            updated.attachmentCacheKey = message.attachmentCacheKey
            updated.attachmentVersion = message.attachmentVersion
            updated.attachmentChecksum = message.attachmentChecksum
            updated.attachmentMediaCategory = message.attachmentMediaCategory
            updated.attachmentExtension = message.attachmentExtension
            updated.attachmentThumbnailURL = message.attachmentThumbnailURL
            updated.attachmentPosterURL = message.attachmentPosterURL
            updated.attachmentCoverURL = message.attachmentCoverURL
            updated.attachmentPreviewKind = message.attachmentPreviewKind
            updated.attachmentContentDisposition = message.attachmentContentDisposition
            updated.attachmentWidth = message.attachmentWidth
            updated.attachmentHeight = message.attachmentHeight
            updated.attachmentDurationSeconds = message.attachmentDurationSeconds
            updated.attachmentUploadStatus = message.attachmentUploadStatus
            updated.attachmentUploadFailure = message.attachmentUploadFailure
            guard updated != previous else { return nil }
            conversation.messages[mIndex] = updated
            if let latest = latestConfirmedMessage(in: conversation.messages) {
                conversation.lastMessage = conversationListPreview(latest)
                conversation.time = latest.time
                conversation.sortTimestamp = max(conversation.sortTimestamp, effectiveCreatedAt(for: latest)?.timeIntervalSince1970 ?? 0)
            }
            commitConversationSnapshot(conversation, at: cIndex)
            return updated
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    /// 历史窗口扩展(如跳转置顶/搜索目标前的水合)后,把已落入加载窗口的
    /// 置顶上下文消息恢复为普通时间线行,否则时间线渲染仍会把它过滤掉,
    /// scrollTo 找不到对应行导致定位失败。
    func normalizePinnedContextMessagesWithinLoadedWindow(conversationID: String) {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            let oldestLoadedTimelineSeq = conversationMessageSnapshot(at: index).messages
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
            let indices = conversationMessageSnapshot(at: index).messages.indices.filter {
                conversationMessageSnapshot(at: index).messages[$0].isPinnedContextOnly
                    && conversationMessageSnapshot(at: index).messages[$0].channelSeq >= oldestLoadedTimelineSeq
            }
            guard !indices.isEmpty else { return }
            mutateStoredMessageWindow(inConversationAt: index) { messages in
                for mIndex in indices {
                    messages[mIndex].isPinnedContextOnly = false
                }
            }
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func applyingPinnedMessageSnapshot(
        _ entries: [PinnedMessageSnapshotEntry],
        to conversation: ConversationMessageSnapshot
    ) -> ConversationMessageSnapshot {
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
    ) -> ConversationMessageSnapshot? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedConversationID.isEmpty,
                  let index = conversations.firstIndex(where: { $0.id == normalizedConversationID }) else { return nil }
            let updated = applyingPinnedMessageSnapshot(entries, to: conversationMessageSnapshot(at: index))
            commitConversationSnapshot(updated, at: index)
            return updated
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func setContactCardAttachmentMeta(messageID: String, conversationID: String, contactID: String) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContactID = contactID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  !normalizedContactID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }),
                  conversationMessageSnapshot(at: cIndex).messages[mIndex].kind == .contactCard else { return false }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) { $0.attachmentMeta = normalizedContactID }
            return true
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func prepareMessageForResend(
        messageID: String,
        conversationID: String,
        createdAt: Date = Date(),
        readBy: [ReadReceipt]
    ) -> ChatMessage? {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty,
                  !normalizedConversationID.isEmpty,
                  let cIndex = conversations.firstIndex(where: { $0.id == normalizedConversationID }),
                  let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { return nil }
            mutateStoredMessage(at: mIndex, inConversationAt: cIndex) {
                $0.status = .sending
                $0.createdAt = createdAt
                $0.readBy = readBy
            }
            return conversationMessageSnapshot(at: cIndex).messages[mIndex]
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
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
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRequestID.isEmpty else { return 0 }
            var updatedCount = 0
            let unreadRevision = memorySnapshot.revision
            var next = conversationMessageSnapshots()
            var changedIndices = Set<Int>()
            for cIndex in next.indices {
                for mIndex in next[cIndex].messages.indices {
                    guard let approval = next[cIndex].messages[mIndex].groupInviteApproval,
                          approval.requestID.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedRequestID else { continue }
                    next[cIndex].messages[mIndex].groupInviteApproval = approval.resolved(
                        status: status,
                        approverName: approverName,
                        approverAccountID: approverAccountID,
                        decidedAt: decidedAt,
                        resultText: resultText
                    )
                    updatedCount += 1
                    changedIndices.insert(cIndex)
                }
            }
            if updatedCount > 0 { commitConversationChanges(in: next, at: changedIndices, preparedAt: unreadRevision) }
            return updatedCount
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    @discardableResult
    func applyRecall(
        messageID: String,
        conversationID: String? = nil,
        recallText: String? = nil,
        channelIDForConversation: ((ConversationMessageSnapshot) -> String)? = nil
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty else { return false }
            let normalizedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for cIndex in conversations.indices {
                guard let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { continue }
                if !normalizedConversationID.isEmpty,
                   conversationMessageSnapshot(at: cIndex).id != normalizedConversationID,
                   channelIDForConversation?(conversationMessageSnapshot(at: cIndex)) != normalizedConversationID {
                    continue
                }
                let original = conversationMessageSnapshot(at: cIndex).messages[mIndex]
                guard !original.isDeletedLocally else { return true }
                var recalled = original
                markMessageAsRecalled(&recalled, recallText: recallText)
                if recalled != original {
                    mutateStoredConversation(at: cIndex) { conversation in
                        conversation.messages[mIndex] = recalled
                        updateConversationLatestFromMessages(&conversation)
                    }
                }
                return true
            }
            return false
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    /// 冷读(历史分页/重进会话)时,消息本体 status 已是 recalled 但 payload
    /// 仍保留原文,映射阶段直接按撤回墓碑清洗,不依赖 message-extras 补丁。
    func markMessageAsRecalledFromRemoteStatus(_ message: inout ChatMessage) {
        markMessageAsRecalled(&message, recallText: nil)
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
        channelIDForConversation: (ConversationMessageSnapshot) -> String
    ) -> Bool {
        return performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageID.isEmpty else { return false }
            for cIndex in conversations.indices {
                if let conversationID,
                   conversationMessageSnapshot(at: cIndex).id != conversationID,
                   channelIDForConversation(conversationMessageSnapshot(at: cIndex)) != conversationID {
                    continue
                }
                guard let mIndex = conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == normalizedMessageID }) else { continue }
                let message = conversationMessageSnapshot(at: cIndex).messages[mIndex]
                guard !message.isDeletedLocally else { return true }
                mutateStoredConversation(at: cIndex) { conversation in
                    markMessageAsAdminDeleted(&conversation.messages[mIndex])
                    if message.channelSeq >= conversation.lastMsgSeq {
                        if latestConfirmedMessage(in: conversation.messages) != nil {
                            updateConversationLatestFromMessages(&conversation)
                        } else {
                            conversation.lastMessage = ""
                            conversation.time = ""
                        }
                    }
                }
                return true
            }
            return false
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
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

}
// WDT_IOS1_REFACTOR_LOCAL_MESSAGE_MUTATION_BOUNDARY_20261110_END
// WDT_IOS1_REFACTOR_CONVERSATION_MEMORY_COMMIT_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END // WDT_IOS1_INCREMENTAL_UNREAD_20261110_END

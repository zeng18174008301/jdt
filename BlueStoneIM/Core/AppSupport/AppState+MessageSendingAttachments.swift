import Combine
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

// MARK: - Message Sending and Attachment Uploads

private struct RetryableMessageSendAuthorizationError: Error {}

extension AppState {
    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_APPSTATE_HELPERS - 修改开始：统一发送/上传链路诊断日志
    private func chatBackSendDiagnostic(
        _ event: String,
        conversationID: String,
        messageID: String? = nil,
        extra: String = ""
    ) {
#if DEBUG
        let messagePart = messageID.map { " message=\(Self.shortDebugID($0))" } ?? ""
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[JHT ChatBackDiag] event=\(event) conversation=\(Self.shortDebugID(conversationID))\(messagePart)\(suffix)")
#endif
    }

    private static func chatBackDiagnosticElapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_APPSTATE_HELPERS - 修改结束：统一发送/上传链路诊断日志

    func prepareDurableReadAckTicket(
        conversation: Conversation,
        context: IMAPIContext,
        scope: String
    ) async throws -> LocalMessageSessionTicket {
        let generation = localMessageSessionGeneration
        guard isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let ticket: LocalMessageSessionTicket
        if let localMessageTicket {
            ticket = localMessageTicket
        } else {
            ticket = try await messagePersistence.ensureTicket(
                context: context,
                sessionGeneration: generation
            )
        }
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope),
              ticket.sessionGeneration == generation else {
            throw LocalMessageDatabaseError.staleSession
        }
        let cacheableConversation = shouldShowGroupMemberCount
            ? conversation
            : conversation.scrubbingGroupMemberTotals()
        let snapshot = localMessageSnapshot(
            from: cacheableConversation,
            actorID: (context.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            projectedMessages: cacheableConversation.messages
        )
        _ = try await messagePersistence.persist(
            ticket: ticket,
            snapshots: [snapshot],
            source: .localMutation,
            revision: nextLocalMessageProjectionRevision(),
            replaceMissingConversations: false
        )
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        localMessageTicket = ticket
        return ticket
    }

    private func conversationForDurableReadAck(channelID: String) -> Conversation? {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else { return nil }
        return conversations.first { conversation in
            conversation.kind != .system
                && remoteChannelID(for: conversation) == normalizedChannelID
        }
    }

    @discardableResult
    func scheduleDurableReadAckRecovery(
        ticket: LocalMessageSessionTicket,
        runImmediately: Bool = false,
        requiresActiveScene: Bool = true
    ) -> Task<Void, Never>? {
        guard (!requiresActiveScene || iosRiskTelemetrySceneIsActive),
              isAuthenticated,
              apiContext.hasIMSession,
              localMessageTicket?.scopeHash == ticket.scopeHash else { return nil }
        if let durableReadAckRecoveryTask {
            if durableReadAckRecoveryTask.isCancelled {
                durableReadAckRecoveryRestartRequested = true
            }
            return durableReadAckRecoveryTask
        }
        let scope = remoteDataScopeKey(for: apiContext)
        durableReadAckRecoveryGeneration &+= 1
        let generation = durableReadAckRecoveryGeneration
        durableReadAckRecoveryRestartRequested = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDurableReadAckRecoveryLoop(
                ticket: ticket,
                scope: scope,
                runImmediately: runImmediately,
                requiresActiveScene: requiresActiveScene
            )
            self.finishDurableReadAckRecovery(
                generation: generation,
                ticket: ticket,
                requiresActiveScene: requiresActiveScene
            )
        }
        durableReadAckRecoveryTask = task
        return task
    }

    private func durableReadAckRecoveryIsEligible(
        ticket: LocalMessageSessionTicket,
        scope: String,
        requiresActiveScene: Bool
    ) -> Bool {
        !Task.isCancelled
            && (!requiresActiveScene || iosRiskTelemetrySceneIsActive)
            && isAuthenticated
            && apiContext.hasIMSession
            && isCurrentRemoteScope(scope)
            && localMessageTicket?.scopeHash == ticket.scopeHash
    }

    private func runDurableReadAckRecoveryLoop(
        ticket: LocalMessageSessionTicket,
        scope: String,
        runImmediately: Bool,
        requiresActiveScene: Bool
    ) async {
        _ = runImmediately
        while durableReadAckRecoveryIsEligible(
            ticket: ticket,
            scope: scope,
            requiresActiveScene: requiresActiveScene
        ) {
            let recoverable: [LocalMessagePendingAck]
            do {
                recoverable = try await messagePersistence.recoverableAcks(
                    ticket: ticket,
                    type: "read"
                )
            } catch {
                return
            }
            guard durableReadAckRecoveryIsEligible(
                ticket: ticket,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            ), !recoverable.isEmpty else { return }
            let nextRetryAt = recoverable.compactMap(\.retryAt).min()
                ?? Date().timeIntervalSince1970
            let delay = max(0, nextRetryAt - Date().timeIntervalSince1970)
            if delay > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(min(delay, 60) * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            guard durableReadAckRecoveryIsEligible(
                ticket: ticket,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            ) else { return }
            let items: [LocalMessagePendingAck]
            do {
                items = try await messagePersistence.claimAcksForRetry(
                    ticket: ticket,
                    type: "read",
                    limit: 1
                )
            } catch {
                return
            }
            guard let item = items.first else {
                await Task.yield()
                continue
            }
            guard durableReadAckRecoveryIsEligible(
                ticket: ticket,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            ) else {
                try? await messagePersistence.abandonAckClaimWithoutConsumingAttempt(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type,
                    claimedSeq: item.desiredSeq,
                    claimedAttemptCount: item.attemptCount
                )
                return
            }
            guard let conversation = conversationForDurableReadAck(channelID: item.channelID) else {
                try? await messagePersistence.abandonAckClaimWithoutConsumingAttempt(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type,
                    claimedSeq: item.desiredSeq,
                    claimedAttemptCount: item.attemptCount
                )
                continue
            }
            _ = await sendDurableReadAck(
                item,
                ticket: ticket,
                conversation: conversation,
                context: apiContext,
                scope: scope,
                requiresActiveScene: requiresActiveScene
            )
        }
    }

    private func finishDurableReadAckRecovery(
        generation: UInt64,
        ticket: LocalMessageSessionTicket,
        requiresActiveScene: Bool
    ) {
        guard durableReadAckRecoveryGeneration == generation else { return }
        durableReadAckRecoveryTask = nil
        let shouldRestart = durableReadAckRecoveryRestartRequested
        durableReadAckRecoveryRestartRequested = false
        if shouldRestart {
            scheduleDurableReadAckRecovery(
                ticket: ticket,
                runImmediately: true,
                requiresActiveScene: requiresActiveScene
            )
        }
    }

#if DEBUG
    func recoverDurableReadAcksForTesting(requiresActiveScene: Bool = false) async {
        guard let ticket = localMessageTicket else { return }
        let task = scheduleDurableReadAckRecovery(
            ticket: ticket,
            runImmediately: true,
            requiresActiveScene: requiresActiveScene
        )
        await task?.value
    }
#endif

    @discardableResult
    func sendDurableReadAck(
        _ item: LocalMessagePendingAck,
        ticket: LocalMessageSessionTicket,
        conversation: Conversation,
        context: IMAPIContext,
        scope: String,
        requiresActiveScene: Bool = false
    ) async -> Bool {
        guard durableReadAckRecoveryIsEligible(
            ticket: ticket,
            scope: scope,
            requiresActiveScene: requiresActiveScene
        ) else {
            try? await messagePersistence.abandonAckClaimWithoutConsumingAttempt(
                ticket: ticket,
                channelKey: item.channelID,
                type: item.type,
                claimedSeq: item.desiredSeq,
                claimedAttemptCount: item.attemptCount
            )
            return false
        }
        do {
            let response = try await api.readAck(
                context: context,
                conversation: conversation,
                channelID: item.channelID,
                throughSeq: item.desiredSeq
            )
            guard isCurrentRemoteScope(scope),
                  localMessageTicket?.scopeHash == ticket.scopeHash else { return false }
            applyRemoteReadReceipts(
                response.readReceipts,
                channelID: response.channelID.isEmpty ? item.channelID : response.channelID
            )
            let confirmedSeq = max(0, response.lastReadSeq ?? 0)
            if confirmedSeq > 0 {
                try await messagePersistence.confirmAck(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type,
                    confirmedSeq: confirmedSeq
                )
                conversationStore.advanceRead(
                    conversationID: conversation.id,
                    through: confirmedSeq
                )
                let effectiveReadSeq = rememberConversationReadLocally(
                    conversation,
                    through: confirmedSeq
                )
                cancelLocalNotificationsForCurrentRead(
                    channelID: item.channelID,
                    channelType: apiChannelType(for: conversation.kind),
                    throughSeq: effectiveReadSeq
                )
            }
            guard confirmedSeq >= item.desiredSeq else {
                try? await messagePersistence.releaseAckForRetry(
                    ticket: ticket,
                    channelKey: item.channelID,
                    type: item.type
                )
                return false
            }
            return true
        } catch {
            try? await messagePersistence.releaseAckForRetry(
                ticket: ticket,
                channelKey: item.channelID,
                type: item.type
            )
            return false
        }
    }

    func reconcileDurableReadAckProjection(
        ticket: LocalMessageSessionTicket,
        scope: String
    ) async {
        guard isCurrentRemoteScope(scope),
              localMessageTicket?.scopeHash == ticket.scopeHash else { return }
        guard let states = try? await messagePersistence.ackStates(
            ticket: ticket,
            type: "read"
        ) else { return }
        for state in states where state.confirmedSeq > 0 {
            guard let conversation = conversationForDurableReadAck(channelID: state.channelID) else {
                continue
            }
            conversationStore.advanceRead(
                conversationID: conversation.id,
                through: state.confirmedSeq
            )
            _ = rememberConversationReadLocally(
                conversation,
                through: state.confirmedSeq
            )
        }
    }

    func enqueueDurableOutgoing(
        messageID: String,
        conversationID: String,
        operationKind: String,
        context: IMAPIContext,
        scope: String,
        attachmentData: Data? = nil,
        attachmentFileURL: URL? = nil,
        attachmentSizeBytes: Int64? = nil,
        attachmentName: String = "",
        attachmentMimeType: String = ""
    ) async throws -> LocalMessageSessionTicket {
        let generation = localMessageSessionGeneration
        guard isCurrentRemoteScope(scope),
              let conversation = conversations.first(where: { $0.id == conversationID }),
              let message = conversation.messages.first(where: { $0.id == messageID }) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let ticket: LocalMessageSessionTicket
        if let localMessageTicket {
            ticket = localMessageTicket
        } else {
            ticket = try await messagePersistence.ensureTicket(
                context: context,
                sessionGeneration: generation
            )
        }
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        let attachment: LocalMessageAttachmentIntent?
        if let data = attachmentData {
            attachment = LocalMessageAttachmentIntent(
                data: data,
                fileName: attachmentName,
                mimeType: attachmentMimeType,
                sizeBytes: Int64(data.count),
                checksum: AttachmentTransferRepository.sha256Hex(data)
            )
        } else if let attachmentFileURL,
                  let attachmentSizeBytes {
            attachment = LocalMessageAttachmentIntent(
                fileURL: attachmentFileURL,
                fileName: attachmentName,
                mimeType: attachmentMimeType,
                sizeBytes: attachmentSizeBytes
            )
        } else {
            attachment = nil
        }
        let snapshot = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: remoteChannelID(for: conversation),
            channelType: apiChannelType(for: conversation.kind),
            currentActorID: context.imUID ?? ""
        )
        _ = try await messagePersistence.enqueueOutgoing(
            ticket: ticket,
            intent: LocalMessageOutgoingIntent(
                conversation: snapshot,
                message: CachedMessage(message: message),
                operationKind: operationKind,
                attachment: attachment
            ),
            revision: nextLocalMessageProjectionRevision()
        )
        guard generation == localMessageSessionGeneration,
              isCurrentRemoteScope(scope) else {
            throw LocalMessageDatabaseError.staleSession
        }
        localMessageTicket = ticket
        try await messagePersistence.updateOutboxState(
            ticket: ticket,
            clientMessageID: messageID,
            state: .sending
        )
        return ticket
    }

    func confirmDurableOutgoing(
        ticket: LocalMessageSessionTicket,
        clientMessageID: String,
        remote: RemoteMessage,
        conversationID: String,
        scope: String
    ) async {
        guard isCurrentRemoteScope(scope),
              remote.channelSeq > 0,
              !remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let projection = LocalMessageConversationSnapshot(
            conversation: conversation,
            channelID: remote.channelID.isEmpty ? remoteChannelID(for: conversation) : remote.channelID,
            channelType: remote.channelType.isEmpty ? apiChannelType(for: conversation.kind) : remote.channelType,
            currentActorID: apiContext.imUID ?? ""
        )
        do {
            try await messagePersistence.confirmOutgoing(
                ticket: ticket,
                clientMessageID: clientMessageID,
                authoritativeMessageID: remote.messageID,
                authoritativeChannelSeq: remote.channelSeq,
                projection: projection,
                revision: nextLocalMessageProjectionRevision()
            )
            scheduleDurableOutboxRecovery(ticket: ticket)
        } catch {
            // Realtime/history readback can still close the same authority by
            // client_msg_no; never issue a second identity here.
        }
    }

    @discardableResult
    func updateDurableOutbox(
        ticket: LocalMessageSessionTicket?,
        messageID: String,
        state: LocalMessageOutboxState,
        uncertain: Bool = false,
        fileID: String? = nil,
        attachmentPhase: String? = nil
    ) async -> Bool {
        guard let ticket else { return false }
        do {
            try await messagePersistence.updateOutboxState(
                ticket: ticket,
                clientMessageID: messageID,
                state: state,
                uncertain: uncertain,
                fileID: fileID,
                attachmentPhase: attachmentPhase
            )
            if state == .retryWait || state == .uncertain {
                scheduleDurableOutboxRecovery(ticket: ticket)
            }
            return true
        } catch {
            // The outbox write remains authoritative. A scope transition or a
            // later foreground activation will reopen and recover it.
            return false
        }
    }

    func scheduleDurableOutboxRecovery(ticket: LocalMessageSessionTicket) {
        guard iosRiskTelemetrySceneIsActive,
              isAuthenticated,
              apiContext.hasIMSession,
              localMessageTicket?.scopeHash == ticket.scopeHash else { return }
        let scope = remoteDataScopeKey(for: apiContext)
        durableOutboxRecoveryTask?.cancel()
        durableOutboxRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recoverable: [LocalMessageRecoveredOutbox]
            do {
                recoverable = try await self.messagePersistence.recoverableOutbox(ticket: ticket)
            } catch {
                self.durableOutboxRecoveryTask = nil
                return
            }
            guard !Task.isCancelled,
                  self.isCurrentRemoteScope(scope),
                  self.localMessageTicket?.scopeHash == ticket.scopeHash else {
                self.durableOutboxRecoveryTask = nil
                return
            }
            let automatic = recoverable.filter { !$0.requiresUserInitiatedReplay }
            guard !automatic.isEmpty else {
                self.durableOutboxRecoveryTask = nil
                return
            }
            let nextAttemptAt = automatic.compactMap(\.nextAttemptAt).min()
                ?? Date().timeIntervalSince1970
            let delay = max(0, nextAttemptAt - Date().timeIntervalSince1970)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(delay, 5 * 60) * 1_000_000_000))
                } catch {
                    self.durableOutboxRecoveryTask = nil
                    return
                }
            }
            guard !Task.isCancelled,
                  self.iosRiskTelemetrySceneIsActive,
                  self.isAuthenticated,
                  self.apiContext.hasIMSession,
                  self.isCurrentRemoteScope(scope),
                  self.localMessageTicket?.scopeHash == ticket.scopeHash else {
                self.durableOutboxRecoveryTask = nil
                return
            }
            self.durableOutboxRecoveryTask = nil
            await self.recoverDurableOutbox(ticket: ticket, scope: scope)
        }
    }

    // JHT_MOD_BEGIN ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改开始：锁屏/后台回来后继续图片、文件附件发送
    func suspendPendingAttachmentUploadsForBackground() {
        attachmentForegroundResumeGeneration &+= 1
        attachmentForegroundResumeTask?.cancel()
        attachmentForegroundResumeTask = nil
        let uploadOperationIDs = Array(attachmentUploadOperations.keys)
        guard !uploadOperationIDs.isEmpty else { return }
        var suspendedCount = 0
        for messageID in uploadOperationIDs {
            guard let pending = fileStore.pendingAttachmentUpload(messageID: messageID),
                  pending.kind == .image || pending.kind == .file,
                  let operation = attachmentUploadOperations[messageID] else { continue }
            operation.task.cancel()
            attachmentUploadOperations[messageID] = nil
            fileStore.finishAttachmentUploadTask(messageID: messageID)
            suspendedCount += 1
        }
        #if DEBUG
        if suspendedCount > 0 {
            print("[JHT AttachmentResume] background_suspend count=\(suspendedCount)")
        }
        #endif
    }

    func resumePendingAttachmentUploadsAfterForeground(scope: String) {
        guard iosRiskTelemetrySceneIsActive,
              isAuthenticated,
              apiContext.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        attachmentForegroundResumeGeneration &+= 1
        let generation = attachmentForegroundResumeGeneration
        attachmentForegroundResumeTask?.cancel()
        attachmentForegroundResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.attachmentForegroundResumeGeneration == generation,
                  self.iosRiskTelemetrySceneIsActive,
                  self.isAuthenticated,
                  self.apiContext.hasIMSession,
                  self.isCurrentRemoteScope(scope) else {
                if self.attachmentForegroundResumeGeneration == generation {
                    self.attachmentForegroundResumeTask = nil
                }
                return
            }
            let candidates = self.pendingAttachmentUploadForegroundResumeCandidates()
            guard !candidates.isEmpty else {
                self.attachmentForegroundResumeTask = nil
                return
            }
            var startedCount = 0
            var skippedRunningCount = 0
            var previousTaskByConversationID: [String: Task<Void, Never>] = [:]
            for candidate in candidates {
                guard !Task.isCancelled,
                      self.attachmentForegroundResumeGeneration == generation,
                      self.iosRiskTelemetrySceneIsActive,
                      self.isCurrentRemoteScope(scope) else { return }
                guard self.fileStore.hasPendingAttachmentUpload(messageID: candidate.messageID) else { continue }
                guard !self.fileStore.hasAttachmentUploadTask(messageID: candidate.messageID) else {
                    skippedRunningCount += 1
                    continue
                }
                let task = self.startAttachmentUploadTask(
                    messageID: candidate.messageID,
                    in: candidate.conversationID,
                    after: previousTaskByConversationID[candidate.conversationID]
                )
                previousTaskByConversationID[candidate.conversationID] = task
                startedCount += 1
            }
            self.attachmentForegroundResumeTask = nil
            #if DEBUG
            print("[JHT AttachmentResume] foreground_resume candidates=\(candidates.count) started=\(startedCount) skipped_running=\(skippedRunningCount)")
            #endif
        }
    }

    private func pendingAttachmentUploadForegroundResumeCandidates() -> [(conversationID: String, messageID: String)] {
        var seenMessageIDs = Set<String>()
        var candidates: [(conversationID: String, messageID: String)] = []
        for conversation in conversations where conversation.kind != .system {
            for message in conversation.messages {
                guard shouldResumeAttachmentUploadAfterForeground(message),
                      let pending = fileStore.pendingAttachmentUpload(messageID: message.id),
                      pending.kind == .image || pending.kind == .file,
                      seenMessageIDs.insert(message.id).inserted else {
                    continue
                }
                candidates.append((conversation.id, message.id))
            }
        }
        return candidates
    }

    private func shouldResumeAttachmentUploadAfterForeground(_ message: ChatMessage) -> Bool {
        guard message.isOutgoing,
              message.kind == .image || message.kind == .file else { return false }
        let status = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if message.status == .failed {
            guard !status.isEmpty else { return true }
            return status == "failed"
                || status == "retry_wait"
                || status == "failed_retryable"
                || AttachmentUploadPhase.failurePhase(from: status) != nil
        }
        guard message.status == .sending else { return false }
        guard !status.isEmpty else { return true }
        return [
            "queued",
            "config",
            "presign",
            "put",
            "uploading",
            "uploaded",
            "finalize",
            "finalized",
            "processing",
            "send",
            "message_send",
            "awaiting_ack",
            "awaiting_acknowledgement",
            "preparing",
            "sending",
            "retrying",
            "pending",
            "in_progress",
            "准备中",
            "准备上传",
            "发送中",
            "处理中"
        ].contains(status)
    }
    // JHT_MOD_END ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改结束

    private func shouldSyncConversationAfterSendConfirmation(_ remote: RemoteMessage) -> Bool {
        remote.channelSeq <= 0 || !isRealtimeConnected
    }

    private func sendTextRecoveringUncertainOutcomeOnce(
        context: IMAPIContext,
        scope: String,
        conversation: Conversation,
        channelID: String,
        text: String,
        quote: String?,
        replyContext: MessageReplyContext?,
        clientMessageID: String,
        mentionAll: Bool,
        mentionedUsers: [MentionIdentity]
    ) async throws -> RemoteMessage {
        var sendContext = context
        var repeatedSend = false
        while true {
            do {
                return try await api.sendText(
                    context: sendContext,
                    conversation: conversation,
                    channelID: channelID,
                    text: text,
                    quote: quote,
                    replyContext: replyContext,
                    clientMessageID: clientMessageID,
                    mentionAll: mentionAll,
                    mentionedUsers: mentionedUsers
                )
            } catch is MessageSendOutcomeUncertainError {
                // The server may already have committed the first POST. The
                // message contract is idempotent by client_msg_no, so repeat
                // exactly once with the same identity and never fan out across
                // runtime endpoints.
                guard !repeatedSend else { throw MessageSendOutcomeUncertainError() }
                repeatedSend = true
            } catch {
                guard isUnauthorizedError(error) else { throw error }
                // A raw message 401 is not logout authority. Refresh first,
                // and reserve the only repeat-send budget for the refreshed
                // session. A second 401 remains a retryable bubble unless the
                // refresh endpoint itself proved terminal revocation.
                guard !repeatedSend else { throw RetryableMessageSendAuthorizationError() }
                let refreshed = await refreshStoredAuthSessionIfNeeded(
                    reason: "message_send",
                    silent: true,
                    context: sendContext,
                    scope: scope
                )
                guard refreshed,
                      isCurrentRemoteScope(scope),
                      apiContext.hasIMSession else {
                    throw RetryableMessageSendAuthorizationError()
                }
                repeatedSend = true
                sendContext = apiContext
            }
        }
    }

    @discardableResult
    func sendText(
        _ text: String,
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext? = nil,
        mentionAll: Bool = false,
        mentionedUsers: [MentionIdentity] = [],
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) -> Bool {
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_ENTER - 修改开始：定位文本发送同步入口耗时
        let sendTextDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_ENTER - 修改结束：定位文本发送同步入口耗时
        let trimmed = normalizedSendableMessageText(text)
        guard !trimmed.isEmpty,
              let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_LOG_ENTER - 修改开始：记录文本发送入口，不输出正文
        chatBackSendDiagnostic(
            "app_send_text_enter",
            conversationID: conversationID,
            extra: "text_len=\(trimmed.count) mention_all=\(mentionAll) mentions=\(mentionedUsers.count) messages=\(conversations[cIndex].messages.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_LOG_ENTER - 修改结束：记录文本发送入口，不输出正文
        if isSystemReadOnlyConversation(conversations[cIndex]) {
            toast = "系统通知仅支持阅读"
            return false
        }
        if let message = directSendBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return false
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_text")
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: trimmed,
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: .text,
            reactions: [],
            readBy: [],
            unreadBy: conversations[cIndex].participants.prefix(3).map { ReadReceipt(id: "pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: nil,
            attachmentMeta: nil
        )
        message.createdAt = Date()
        message.replyContext = replyContext
        message.mentionAll = mentionAll
        message.mentionedUsers = mentionedUsers
        guard let conversation = conversationStore.appendLocalOutgoingMessage(
            message,
            to: conversationID,
            preview: trimmed
        ) else { return false }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_LOCAL_APPEND - 修改开始：记录文本本地消息追加耗时
        chatBackSendDiagnostic(
            "app_send_text_local_appended",
            conversationID: conversationID,
            messageID: message.id,
            extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendTextDiagnosticStartedAt)) messages=\(conversation.messages.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_LOCAL_APPEND - 修改结束：记录文本本地消息追加耗时
        let channelID = remoteChannelID(for: conversation)
        Task {
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_TASK - 修改开始：记录文本发送异步任务耗时
            let sendTextTaskStartedAt = CFAbsoluteTimeGetCurrent()
            chatBackSendDiagnostic(
                "app_send_text_task_start",
                conversationID: conversationID,
                messageID: message.id
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_TASK - 修改结束：记录文本发送异步任务耗时
            var durableTicket: LocalMessageSessionTicket?
            do {
                durableTicket = try await enqueueDurableOutgoing(
                    messageID: message.id,
                    conversationID: conversationID,
                    operationKind: "send_text",
                    context: context,
                    scope: scope
                )
                let remote = try await sendTextRecoveringUncertainOutcomeOnce(
                    context: context,
                    scope: scope,
                    conversation: conversation,
                    channelID: channelID,
                    text: trimmed,
                    quote: quote,
                    replyContext: replyContext,
                    clientMessageID: message.id,
                    mentionAll: mentionAll,
                    mentionedUsers: mentionedUsers
                )
                guard isCurrentRemoteScope(scope) else { return }
                let needsCompensationSync = shouldSyncConversationAfterSendConfirmation(remote)
                replaceMessageID(localID: message.id, remote: remote, in: conversationID)
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_CONFIRMED - 修改开始：记录文本远端确认到本地替换耗时
                chatBackSendDiagnostic(
                    "app_send_text_remote_confirmed",
                    conversationID: conversationID,
                    messageID: message.id,
                    extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendTextTaskStartedAt)) compensation=\(needsCompensationSync)"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_CONFIRMED - 修改结束：记录文本远端确认到本地替换耗时
                if let durableTicket {
                    await confirmDurableOutgoing(
                        ticket: durableTicket,
                        clientMessageID: message.id,
                        remote: remote,
                        conversationID: conversationID,
                        scope: scope
                    )
                }
                if needsCompensationSync {
                    syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
                }
            } catch is RetryableMessageSendAuthorizationError {
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_AUTH_RETRY - 修改开始：记录文本发送鉴权重试失败耗时
                chatBackSendDiagnostic(
                    "app_send_text_task_failed",
                    conversationID: conversationID,
                    messageID: message.id,
                    extra: "reason=auth_retry elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendTextTaskStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_AUTH_RETRY - 修改结束：记录文本发送鉴权重试失败耗时
                guard isCurrentRemoteScope(scope) else { return }
                await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                markMessageFailed(messageID: message.id, in: conversationID)
                toast = "消息发送失败，可点击重发"
            } catch is MessageSendOutcomeUncertainError {
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_UNCERTAIN - 修改开始：记录文本发送状态未确认耗时
                chatBackSendDiagnostic(
                    "app_send_text_task_failed",
                    conversationID: conversationID,
                    messageID: message.id,
                    extra: "reason=uncertain elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendTextTaskStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_UNCERTAIN - 修改结束：记录文本发送状态未确认耗时
                guard isCurrentRemoteScope(scope) else { return }
                await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .uncertain, uncertain: true)
                markMessageFailed(messageID: message.id, in: conversationID)
                toast = "消息发送状态未确认，可点击重发"
            } catch {
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_FAILED - 修改开始：记录文本发送普通失败耗时
                chatBackSendDiagnostic(
                    "app_send_text_task_failed",
                    conversationID: conversationID,
                    messageID: message.id,
                    extra: "reason=error elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendTextTaskStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_FAILED - 修改结束：记录文本发送普通失败耗时
                guard isCurrentRemoteScope(scope) else { return }
                if isNotFriendsError(error) {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .failedPermanent)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleNotFriends(for: conversation, context: directFriendRequestContext(from: error, fallback: conversation))
                } else if isSendPolicyForbidden(error) {
                    let groupAllMuted = isGroupAllMutedError(error)
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(conversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(conversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .cancelled)
                    handleRemoteError(error, fallback: "消息发送失败")
                    removeMessage(messageID: message.id, in: conversationID)
                    if groupAllMuted {
                        onPolicyRejected?()
                    }
                } else {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleRemoteError(error, fallback: "消息发送失败")
                }
            }
        }
        return true
    }

    @discardableResult
    func sendAttachment(
        kind: MessageKind,
        name: String,
        mimeType: String,
        sizeBytes: Int64?,
        data: Data? = nil,
        fileURL: URL? = nil,
        removeFileWhenFinished: Bool = false,
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext? = nil,
        onPolicyRejected: (@MainActor () -> Void)? = nil,
        automaticallyStartUpload: Bool = true,
        onQueued: ((String) -> Void)? = nil
    ) -> Bool {
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_ENTER - 修改开始：定位附件发送同步入口耗时
        let sendAttachmentDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_ENTER - 修改结束：定位附件发送同步入口耗时
        guard (kind == .image || kind == .file),
              let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_LOG_ENTER - 修改开始：记录附件发送入口，不输出文件名
        chatBackSendDiagnostic(
            "app_send_attachment_enter",
            conversationID: conversationID,
            extra: "kind=\(kind.rawValue) size_bytes=\(sizeBytes ?? -1) data_bytes=\(data?.count ?? -1) file_backed=\(fileURL != nil) auto_start=\(automaticallyStartUpload) messages=\(conversations[cIndex].messages.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_LOG_ENTER - 修改结束：记录附件发送入口，不输出文件名
        if isSystemReadOnlyConversation(conversations[cIndex]) {
            toast = "系统通知仅支持阅读"
            return false
        }
        if let message = directSendBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return false
        }
        let fileSizeBytes = fileURL.flatMap { PendingAttachmentFileStore.fileSize(at: $0) }
        guard data != nil || fileSizeBytes != nil else {
            toast = kind == .image ? "图片数据读取失败，请重新选择后发送" : "文件数据读取失败，请重新选择后发送"
            return false
        }
        guard kind != .image || data?.isEmpty == false || (fileSizeBytes ?? 0) > 0 else {
            toast = "图片数据读取失败，请重新选择后发送"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_attachment")
        var normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (kind == .image ? "图片消息.jpg" : "未命名文件") : name
        let actualSizeBytes = data.map { Int64($0.count) } ?? fileSizeBytes ?? 0
        guard sizeBytes == nil || sizeBytes == actualSizeBytes else {
            toast = "文件大小已变化，请重新选择后发送"
            return false
        }
        let effectiveSizeBytes = sizeBytes ?? actualSizeBytes
        let isGIF: Bool
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_GIF_CHECK - 修改开始：定位 GIF 策略检查耗时
        let gifCheckDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_GIF_CHECK - 修改结束：定位 GIF 策略检查耗时
        do {
            isGIF = try GIFAttachmentUploadPolicy.isGIF(data: data, fileURL: fileURL, name: normalizedName, mimeType: mimeType, maximumAllowedBytes: fileUploadConfig.maxBytes)
        } catch GIFAttachmentUploadPolicy.ValidationError.tooLarge {
            toast = GIFAttachmentUploadPolicy.overLimitMessage(config: fileUploadConfig)
            return false
        } catch {
            toast = GIFAttachmentUploadPolicy.invalidMessage
            return false
        }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_GIF_CHECK_DONE - 修改开始：记录 GIF 策略检查结果
        chatBackSendDiagnostic(
            "app_send_attachment_gif_checked",
            conversationID: conversationID,
            extra: "is_gif=\(isGIF) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: gifCheckDiagnosticStartedAt))"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_GIF_CHECK_DONE - 修改结束：记录 GIF 策略检查结果
        if isGIF, !GIFAttachmentUploadPolicy.allowsUpload(sizeBytes: effectiveSizeBytes, config: fileUploadConfig) {
            toast = GIFAttachmentUploadPolicy.overLimitMessage(config: fileUploadConfig)
            return false
        }
        let kind: MessageKind = isGIF ? .image : kind
        let mimeType = isGIF ? "image/gif" : mimeType
        if isGIF, (normalizedName as NSString).pathExtension.lowercased() != "gif" {
            normalizedName = (normalizedName as NSString).deletingPathExtension + ".gif"
        }
        guard fileUploadConfig.allowsUpload(sizeBytes: effectiveSizeBytes) else {
            toast = fileUploadConfig.overLimitMessage
            return false
        }
        let mediaCategory = inferredAttachmentMediaCategory(kind: kind, name: normalizedName, mimeType: mimeType)
        let meta = attachmentMeta(kind: kind, mimeType: mimeType, sizeBytes: effectiveSizeBytes)
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: normalizedName,
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: kind,
            reactions: [],
            readBy: [],
            unreadBy: conversations[cIndex].participants.prefix(3).map { ReadReceipt(id: "attachment_pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: normalizedName,
            attachmentMeta: meta
        )
        message.createdAt = Date()
        message.replyContext = replyContext
        message.attachmentSizeBytes = effectiveSizeBytes
        message.attachmentMimeType = mimeType
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_INITIAL - 修改开始：入队阶段不写假百分比
        message.attachmentTransferProgress = nil
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_INITIAL - 修改结束
        message.attachmentMediaCategory = mediaCategory
        message.attachmentExtension = (normalizedName as NSString).pathExtension.lowercased()
        message.attachmentPreviewKind = previewKind(forMediaCategory: mediaCategory)
        message.attachmentContentDisposition = ["image", "video", "pdf"].contains(mediaCategory) ? "inline" : "attachment"
        message.attachmentUploadStatus = "queued"
        let localPreview: LocalAttachmentPreviewResources?
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_PREVIEW - 修改开始：定位本地附件预览准备耗时
        let previewDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_PREVIEW - 修改结束：定位本地附件预览准备耗时
        // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：发送入口不在 MainActor 同步写文件/解码图片/生成视频缩略图
        let shouldPrepareLocalPreviewOffMain = fileURL != nil || data != nil
        if let fileURL {
            localPreview = AttachmentPreviewResourceBuilder.lightweightLocalFileResources(
                localURL: fileURL,
                mediaCategory: mediaCategory
            )
        } else {
            localPreview = nil
        }
        // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_PREVIEW_DONE - 修改开始：记录本地附件预览准备结果
        chatBackSendDiagnostic(
            "app_send_attachment_preview_prepared",
            conversationID: conversationID,
            messageID: message.id,
            extra: "media=\(mediaCategory) has_preview=\(localPreview != nil) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: previewDiagnosticStartedAt))"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_PREVIEW_DONE - 修改结束：记录本地附件预览准备结果
        if let localPreview {
            cacheLocalAttachmentResources(localPreview, messageID: message.id)
            applyLocalAttachmentPreviewResources(localPreview, to: &message)
        }
        guard conversationStore.appendLocalOutgoingMessage(message, to: conversationID) != nil else { return false }
        // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：本地消息入队后后台补齐附件预览资源，避免点击发送卡住
        if shouldPrepareLocalPreviewOffMain {
            scheduleOutgoingAttachmentPreviewPreparation(
                messageID: message.id,
                conversationID: conversationID,
                name: normalizedName,
                data: data,
                fileURL: fileURL,
                mediaCategory: mediaCategory
            )
        }
        // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束
        fileStore.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: kind,
            name: normalizedName,
            mimeType: mimeType,
            sizeBytes: effectiveSizeBytes,
            data: data,
            fileURL: fileURL,
            removeFileWhenFinished: removeFileWhenFinished,
            conversationID: conversationID,
            quote: quote,
            replyContext: replyContext,
            onPolicyRejected: onPolicyRejected
        ), messageID: message.id)
        toast = kind == .image ? "图片已加入发送队列" : "文件已加入发送队列"
        onQueued?(message.id)
        if automaticallyStartUpload {
            startAttachmentUploadTask(messageID: message.id, in: conversationID)
        }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_LOCAL_APPEND - 修改开始：记录附件本地消息追加与入队耗时
        chatBackSendDiagnostic(
            "app_send_attachment_local_appended",
            conversationID: conversationID,
            messageID: message.id,
            extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendAttachmentDiagnosticStartedAt)) size_bytes=\(effectiveSizeBytes) auto_start=\(automaticallyStartUpload)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_LOCAL_APPEND - 修改结束：记录附件本地消息追加与入队耗时
        return true
    }

    @discardableResult
    func sendVoiceMessage(
        data: Data,
        name: String,
        mimeType: String = "audio/mp4",
        sizeBytes: Int64? = nil,
        durationMS: Int,
        waveform: [Int],
        conversationID: String,
        quote: String?,
        replyContext: MessageReplyContext? = nil,
        onPolicyRejected: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        if isSystemReadOnlyConversation(conversations[cIndex]) {
            toast = "系统通知仅支持阅读"
            return false
        }
        if let message = directSendBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversations[cIndex]) {
            toast = message
            return false
        }
        guard !VoiceMessagePayload.isTooShort(durationMS: durationMS) else {
            toast = "说话时间太短"
            return false
        }
        guard VoiceMessagePayload.isSendableDurationMS(durationMS) else {
            toast = "语音时长无效，请重新录制"
            return false
        }
        guard !data.isEmpty else {
            toast = "语音数据读取失败，请重新录制"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_voice")
        let normalizedName = voiceMessageFileName(name)
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "audio/mp4" : mimeType
        guard normalizedMimeType.lowercased().hasPrefix("audio/") else {
            toast = "语音格式无效，请重新录制"
            return false
        }
        let effectiveDurationMS = durationMS
        let normalizedWaveform = VoiceMessagePayload.normalizedWaveform(waveform)
        let effectiveSizeBytes = sizeBytes ?? Int64(data.count)
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: VoiceMessagePayload.durationLabel(durationMS: effectiveDurationMS),
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: .voice,
            contentType: "voice",
            reactions: [],
            readBy: [],
            unreadBy: conversations[cIndex].participants.prefix(3).map { ReadReceipt(id: "voice_pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: normalizedName,
            attachmentMeta: voiceAttachmentMeta(durationMS: effectiveDurationMS, sizeBytes: effectiveSizeBytes)
        )
        message.createdAt = Date()
        message.replyContext = replyContext
        message.attachmentSizeBytes = effectiveSizeBytes
        message.attachmentMimeType = normalizedMimeType
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_VOICE_UPLOAD_PROGRESS_INITIAL - 修改开始：语音入队阶段不写假百分比
        message.attachmentTransferProgress = nil
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_VOICE_UPLOAD_PROGRESS_INITIAL - 修改结束
        message.attachmentMediaCategory = "voice"
        message.attachmentExtension = (normalizedName as NSString).pathExtension.lowercased()
        message.attachmentPreviewKind = "voice"
        message.attachmentContentDisposition = "attachment"
        message.attachmentUploadStatus = "queued"
        message.attachmentDurationSeconds = Double(effectiveDurationMS) / 1_000.0
        message.voiceWaveform = normalizedWaveform
        if let localPreview = localAttachmentPreviewResources(
            messageID: message.id,
            name: normalizedName,
            mimeType: normalizedMimeType,
            data: data,
            mediaCategory: "voice"
        ) {
            cacheLocalAttachmentResources(localPreview, messageID: message.id)
            if let downloadURL = localPreview.downloadURL {
                message.attachmentDownloadURL = downloadURL.absoluteString
                message.attachmentDownloadAvailable = true
            }
        }
        guard conversationStore.appendLocalOutgoingMessage(message, to: conversationID) != nil else { return false }
        fileStore.rememberPendingAttachmentUpload(PendingAttachmentUpload(
            kind: .voice,
            name: normalizedName,
            mimeType: normalizedMimeType,
            sizeBytes: effectiveSizeBytes,
            data: data,
            conversationID: conversationID,
            quote: quote,
            replyContext: replyContext,
            voiceDurationMS: effectiveDurationMS,
            voiceWaveform: normalizedWaveform,
            onPolicyRejected: onPolicyRejected
        ), messageID: message.id)
        toast = "语音已加入发送队列"
        startAttachmentUploadTask(messageID: message.id, in: conversationID)
        return true
    }

    func canRetryAttachmentUpload(_ message: ChatMessage) -> Bool {
        fileStore.hasPendingAttachmentUpload(messageID: message.id) && (message.kind == .image || message.kind == .file || message.kind == .voice)
    }

    func retryAttachmentUpload(messageID: String, in conversationID: String) {
        guard let ticket = localMessageTicket else {
            retryClaimedAttachmentUpload(messageID: messageID, in: conversationID, durableTicket: nil)
            return
        }
        Task {
            do {
                let authority = try await messagePersistence.outgoingAuthority(
                    ticket: ticket,
                    clientMessageID: messageID
                )
                guard localMessageTicket?.scopeHash == ticket.scopeHash else { return }
                guard let authority else {
                    retryClaimedAttachmentUpload(messageID: messageID, in: conversationID, durableTicket: nil)
                    return
                }
                if authority.isAcknowledged {
                    syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
                    return
                }
                let claimed = try await messagePersistence.claimOutboxForReplay(
                    ticket: ticket,
                    authorizationGeneration: ticket.sessionGeneration,
                    trigger: .userInitiated,
                    clientMessageID: messageID,
                    limit: 1
                )
                guard localMessageTicket?.scopeHash == ticket.scopeHash else { return }
                guard claimed.contains(where: { $0.clientMessageID == messageID }) else {
                    toast = "附件当前不可重发"
                    return
                }
                retryClaimedAttachmentUpload(messageID: messageID, in: conversationID, durableTicket: ticket)
            } catch {
                guard localMessageTicket?.scopeHash == ticket.scopeHash else { return }
                conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(error: error))
                scheduleConversationSnapshotCacheWrite(conversationID: conversationID, scope: remoteDataScopeKey(for: apiContext))
                toast = "附件重发准备失败，请稍后重试"
            }
        }
    }

    func retryClaimedAttachmentUpload(
        messageID: String,
        in conversationID: String,
        durableTicket: LocalMessageSessionTicket?
    ) {
        guard fileStore.hasPendingAttachmentUpload(messageID: messageID),
              let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[cIndex].messages.contains(where: { $0.id == messageID }) else {
            resendClaimed(messageID: messageID, in: conversationID, durableTicket: durableTicket)
            return
        }
        guard !fileStore.hasAttachmentUploadTask(messageID: messageID) else {
            toast = "附件正在处理中，请勿重复提交"
            return
        }
        if isSystemReadOnlyConversation(conversations[cIndex]) {
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
            toast = "系统通知仅支持阅读"
            return
        }
        if let message = directSendBlockedMessage(for: conversations[cIndex]) {
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
            toast = message
            return
        }
        if let message = localSendPolicyBlockedMessage(for: conversations[cIndex]) {
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
            toast = message
            return
        }
        let failedPhase = conversations[cIndex].messages
            .first(where: { $0.id == messageID })
            .flatMap { AttachmentUploadPhase.failurePhase(from: $0.attachmentUploadStatus) }
        guard conversationStore.markAttachmentUploadRetrying(messageID: messageID, conversationID: conversationID) else { return }
        scheduleConversationSnapshotCacheWrite(conversationID: conversationID, scope: remoteDataScopeKey(for: apiContext))
        toast = attachmentUploadRetryMessage(for: failedPhase)
        startAttachmentUploadTask(messageID: messageID, in: conversationID)
    }

    func cancelAttachmentUpload(messageID: String, in conversationID: String) {
        fileStore.cancelAttachmentUpload(messageID: messageID)
        let ticket = localMessageTicket
        Task {
            await updateDurableOutbox(ticket: ticket, messageID: messageID, state: .cancelled)
        }
        updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
        removeMessage(messageID: messageID, in: conversationID)
        toast = "已取消附件发送"
    }

    func startQueuedAttachmentUploadsInOrder(_ messageIDs: [String], in conversationID: String) {
        var previousTask: Task<Void, Never>?
        for messageID in messageIDs {
            previousTask = startAttachmentUploadTask(messageID: messageID, in: conversationID, after: previousTask)
        }
    }

    @discardableResult
    func startAttachmentUploadTask(messageID: String, in conversationID: String, after previousTask: Task<Void, Never>? = nil) -> Task<Void, Never> {
        let operationID = UUID()
        let context = apiContext
        let generation = localMessageSessionGeneration
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_TASK_CREATE - 修改开始：记录附件上传任务创建与串行等待
        chatBackSendDiagnostic(
            "app_attachment_upload_task_create",
            conversationID: conversationID,
            messageID: messageID,
            extra: "operation=\(Self.shortDebugID(operationID.uuidString)) waits_previous=\(previousTask != nil)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_TASK_CREATE - 修改结束：记录附件上传任务创建与串行等待
        let task = Task { [weak self] in
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_TASK_START - 修改开始：记录附件上传任务进入执行
            self?.chatBackSendDiagnostic(
                "app_attachment_upload_task_waiting",
                conversationID: conversationID,
                messageID: messageID,
                extra: "operation=\(Self.shortDebugID(operationID.uuidString))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_TASK_START - 修改结束：记录附件上传任务进入执行
            await previousTask?.value
            guard !Task.isCancelled else { return }
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_TASK_AFTER_WAIT - 修改开始：记录附件上传任务等待结束
            self?.chatBackSendDiagnostic(
                "app_attachment_upload_task_start",
                conversationID: conversationID,
                messageID: messageID,
                extra: "operation=\(Self.shortDebugID(operationID.uuidString))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_TASK_AFTER_WAIT - 修改结束：记录附件上传任务等待结束
            await self?.uploadPendingAttachment(messageID: messageID, in: conversationID, operationID: operationID, context: context, generation: generation)
        }
        attachmentUploadOperations[messageID] = (operationID, task)
        fileStore.replaceAttachmentUploadTask(messageID: messageID, with: task)
        return task
    }

    private func isCurrentAttachmentUpload(messageID: String, operationID: UUID, context: IMAPIContext, generation: UInt64) -> Bool {
        !Task.isCancelled && attachmentUploadOperations[messageID]?.id == operationID
            && localMessageSessionGeneration == generation
            && apiContext.isSameAuthAuthority(as: context.authSessionFence)
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_UPLOADED_WITHOUT_DESCRIPTOR - 修改开始：识别后端已确认上传完成、无需客户端 PUT 的预签名响应
    private static func remoteFileIsUploaded(_ file: RemoteAvatarFile) -> Bool {
        [file.status, file.uploadStatus]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("uploaded")
    }
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_UPLOADED_WITHOUT_DESCRIPTOR - 修改结束

    func retireAttachmentUploadOperationsForReauthentication() {
        for (messageID, operation) in attachmentUploadOperations {
            operation.task.cancel()
            fileStore.finishAttachmentUploadTask(messageID: messageID)
        }
        attachmentUploadOperations.removeAll()
        // Pending sources, checkpoints and durable outbox/staged files are deliberately retained.
    }

    private func uploadPendingAttachment(messageID: String, in conversationID: String, operationID: UUID, context: IMAPIContext, generation: UInt64) async {
        let uploadDiagnostic = SyncFailureDiagnostic.HTTPObservation(.attachmentUpload)
        defer { uploadDiagnostic.finish() }
        func ownsOperation() -> Bool {
            isCurrentAttachmentUpload(messageID: messageID, operationID: operationID, context: context, generation: generation)
        }
        guard ownsOperation() else { return }
        defer {
            if attachmentUploadOperations[messageID]?.id == operationID {
                attachmentUploadOperations[messageID] = nil
                fileStore.finishAttachmentUploadTask(messageID: messageID)
            }
        }
        guard let pending = fileStore.pendingAttachmentUpload(messageID: messageID),
              let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let conversation = conversations[cIndex]
        let sendFailureFallback = pending.kind == .voice ? "语音发送失败" : "附件发送失败"
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_ENTER - 修改开始：记录附件上传任务进入业务流程
        let uploadDiagnosticStartedAt = CFAbsoluteTimeGetCurrent()
        chatBackSendDiagnostic(
            "app_attachment_upload_enter",
            conversationID: conversationID,
            messageID: messageID,
            extra: "kind=\(pending.kind.rawValue) size_bytes=\(pending.sizeBytes) file_backed=\(pending.fileURL != nil)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_ENTER - 修改结束：记录附件上传任务进入业务流程
        if pending.kind == .voice {
            guard let durationMS = pending.voiceDurationMS,
                  VoiceMessagePayload.isSendableDurationMS(durationMS),
                  pending.mimeType.lowercased().hasPrefix("audio/") else {
                fileStore.finishAttachmentUploadTask(messageID: messageID)
                updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
                conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
                toast = "语音数据无效，请重新录制"
                return
            }
        }
        let scope = remoteDataScopeKey(for: context)
        let channelID = remoteChannelID(for: conversation)
        var durableTicket: LocalMessageSessionTicket?
        var uploadedFileIDForProgressCleanup: String?
        var currentPhase: AttachmentUploadPhase = .config
        func finishStaleAttachmentUpload() {
            guard ownsOperation() else { return }
            fileStore.finishAttachmentUploadTask(messageID: messageID)
            clearAttachmentProgressKeys([messageID, uploadedFileIDForProgressCleanup])
            updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
        }
        func updateUploadOutbox(ticket: LocalMessageSessionTicket?, messageID: String, state: LocalMessageOutboxState, uncertain: Bool = false, fileID: String? = nil, attachmentPhase: String? = nil) async throws {
            guard ownsOperation() else { throw LocalMessageDatabaseError.staleSession }
            let saved = await updateDurableOutbox(ticket: ticket, messageID: messageID, state: state, uncertain: uncertain, fileID: fileID, attachmentPhase: attachmentPhase)
            guard saved, ownsOperation() else { throw LocalMessageDatabaseError.staleSession }
        }
        guard context.hasIMSession else {
            fileStore.finishAttachmentUploadTask(messageID: messageID)
            updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .missingContext))
            toast = "登录会话不可用，请重新登录"
            return
        }
        do {
            durableTicket = try await enqueueDurableOutgoing(
                messageID: messageID,
                conversationID: conversationID,
                operationKind: pending.kind == .voice ? "send_voice" : "send_attachment",
                context: context,
                scope: scope,
                attachmentData: pending.data,
                attachmentFileURL: pending.fileURL,
                attachmentSizeBytes: pending.sizeBytes,
                attachmentName: pending.name,
                attachmentMimeType: pending.mimeType
            )
            guard ownsOperation() else { return }
            if fileStore.attachmentUploadCheckpoint(messageID: messageID) == nil {
                try await updateUploadOutbox(
                    ticket: durableTicket,
                    messageID: messageID,
                    state: .sending,
                    attachmentPhase: "config"
                )
            }
            updateAttachmentUploadPhase(.config, messageID: messageID, in: conversationID)
            let remoteConfig = try await uploadDiagnostic.captureUploadStep {
                try await fetchScopedFileUploadConfig(context: context, scope: scope)
            }
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_CONFIG_READY - 修改开始：记录上传配置阶段耗时
            chatBackSendDiagnostic(
                "app_attachment_upload_config_ready",
                conversationID: conversationID,
                messageID: messageID,
                extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_CONFIG_READY - 修改结束：记录上传配置阶段耗时
            guard ownsOperation() else {
                finishStaleAttachmentUpload()
                return
            }
            let config = remoteConfig.model
            try Task.checkCancellation()
            let gifAllowed = !GIFAttachmentUploadPolicy.isDeclaredGIF(name: pending.name, mimeType: pending.mimeType)
                || GIFAttachmentUploadPolicy.allowsUpload(sizeBytes: pending.sizeBytes, config: config)
            guard config.allowsUpload(sizeBytes: pending.sizeBytes), gifAllowed else {
                try await updateUploadOutbox(
                    ticket: durableTicket,
                    messageID: messageID,
                    state: .cancelled
                )
                fileStore.finishAttachmentUpload(messageID: messageID)
                removeMessage(messageID: messageID, in: conversationID)
                toast = gifAllowed ? config.overLimitMessage : GIFAttachmentUploadPolicy.overLimitMessage(config: config)
                return
            }
            let messageUploadedFile = conversationStore.conversation(id: conversationID)?
                .messages
                .first(where: { $0.id == messageID })
                .flatMap { uploadedFileMetadata(from: $0) }
            let checkpoint = fileStore.attachmentUploadCheckpoint(messageID: messageID)
            let completedFile: RemoteAvatarFile
            if let checkpointCompletedFile = checkpoint?.completedFile ?? messageUploadedFile {
                completedFile = checkpointCompletedFile
                uploadedFileIDForProgressCleanup = checkpointCompletedFile.id
                fileStore.recordAttachmentUploadFinalized(messageID: messageID, file: checkpointCompletedFile)
                // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_RESTORED - 修改开始：恢复已完成文件时不显示阶段百分比
                updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
                // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_RESTORED - 修改结束
            } else {
                var finalizedFileID = checkpoint?.fileID ?? ""
                if checkpoint?.putCompleted != true {
                    currentPhase = .presign
                    try await updateUploadOutbox(
                        ticket: durableTicket,
                        messageID: messageID,
                        state: .sending,
                        attachmentPhase: "presign"
                    )
                    updateAttachmentUploadPhase(.presign, messageID: messageID, in: conversationID)
                    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_PRESIGN - 修改开始：预签名阶段只更新阶段状态，不写假百分比
                    updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
                    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_PRESIGN - 修改结束
                    let voiceAPI = pending.kind == .voice ? api as? IMAPIClient : nil
                    if pending.kind == .voice, voiceAPI == nil {
                        throw IMAPIError.server("voice_attachment_contract_unavailable")
                    }
                    let presign: RemoteAvatarUploadData
                    if let voiceAPI,
                       let durationMS = pending.voiceDurationMS {
                        presign = try await uploadDiagnostic.captureUploadStep {
                            try await voiceAPI.presignVoiceMessageUpload(
                                context: context,
                                conversation: conversation,
                                channelID: channelID,
                                clientMessageID: messageID,
                                fileName: pending.name,
                                mimeType: pending.mimeType,
                                sizeBytes: Int(pending.sizeBytes),
                                durationMS: durationMS,
                                waveform: pending.voiceWaveform
                            )
                        }
                    } else {
                        presign = try await uploadDiagnostic.captureUploadStep {
                            try await api.presignFileUpload(
                                context: context,
                                conversation: conversation,
                                channelID: channelID,
                                clientMessageID: messageID,
                                purpose: "message_attachment",
                                fileName: pending.name,
                                mimeType: pending.mimeType,
                                sizeBytes: Int(pending.sizeBytes)
                            )
                        }
                    }
                    guard ownsOperation() else { return }
                    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_PRESIGNED - 修改开始：记录附件预签名阶段耗时
                    chatBackSendDiagnostic(
                        "app_attachment_upload_presigned",
                        conversationID: conversationID,
                        messageID: messageID,
                        extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
                    )
                    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_PRESIGNED - 修改结束：记录附件预签名阶段耗时
                    finalizedFileID = presign.file.id
                    guard !finalizedFileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw IMAPIError.server("file_id_missing")
                    }
                    fileStore.recordAttachmentUploadPresign(messageID: messageID, fileID: finalizedFileID)
                    uploadedFileIDForProgressCleanup = finalizedFileID
                    try Task.checkCancellation()
                    guard ownsOperation() else {
                        finishStaleAttachmentUpload()
                        return
                    }
                    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_OPTIONAL_PUT - 修改开始：有 upload 描述才执行对象 PUT；已 uploaded 响应直接进入确认阶段
                    if let signedUpload = presign.upload {
                        currentPhase = .put
                        updateAttachmentUploadPhase(.put, messageID: messageID, in: conversationID)
                        updateAttachmentProgress(0, messageID: messageID, in: conversationID)
                        let progress: @Sendable (Double) -> Void = { [weak self] uploadFraction in
                            let clampedFraction = max(0, min(uploadFraction, 1))
                            Task { @MainActor [weak self] in
                                guard let self, self.isCurrentAttachmentUpload(messageID: messageID, operationID: operationID, context: context, generation: generation) else { return }
                                self.updateAttachmentProgress(clampedFraction, messageID: messageID, in: conversationID)
                            }
                        }
                        if let fileURL = pending.fileURL {
                            try await uploadDiagnostic.captureUploadStep {
                                try await api.uploadFileBinary(
                                    upload: signedUpload,
                                    fileURL: fileURL,
                                    mimeType: pending.mimeType,
                                    sizeBytes: pending.sizeBytes,
                                    progress: progress
                                )
                            }
                        } else if let data = pending.data {
                            try await uploadDiagnostic.captureUploadStep {
                                try await api.uploadFileBinary(
                                    upload: signedUpload,
                                    data: data,
                                    mimeType: pending.mimeType,
                                    progress: progress
                                )
                            }
                        } else {
                            throw CocoaError(.fileReadNoSuchFile)
                        }
                        guard ownsOperation() else { return }
                        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_BINARY_DONE - 修改开始：记录附件二进制上传阶段耗时
                        chatBackSendDiagnostic(
                            "app_attachment_upload_binary_done",
                            conversationID: conversationID,
                            messageID: messageID,
                            extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
                        )
                        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_BINARY_DONE - 修改结束：记录附件二进制上传阶段耗时
                    } else if Self.remoteFileIsUploaded(presign.file) {
                        chatBackSendDiagnostic(
                            "app_attachment_upload_already_uploaded",
                            conversationID: conversationID,
                            messageID: messageID,
                            extra: "file=\(Self.shortDebugID(finalizedFileID)) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
                        )
                    } else {
                        throw IMAPIError.server("file_upload_descriptor_missing")
                    }
                    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_OPTIONAL_PUT - 修改结束
                    fileStore.recordAttachmentUploadPUTCompleted(messageID: messageID, fileID: finalizedFileID)
                    try await updateUploadOutbox(
                        ticket: durableTicket,
                        messageID: messageID,
                        state: .sending,
                        fileID: finalizedFileID,
                        attachmentPhase: "uploaded"
                    )
                    try Task.checkCancellation()
                    guard ownsOperation() else {
                        finishStaleAttachmentUpload()
                        return
                    }
                }
                currentPhase = .finalize
                updateAttachmentUploadPhase(.finalize, messageID: messageID, in: conversationID)
                // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_FINALIZE - 修改开始：服务端确认阶段不显示阶段百分比
                updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
                // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_REAL_UPLOAD_PROGRESS_FINALIZE - 修改结束
                let uploadedFile: RemoteAvatarFile
                let voiceAPI = pending.kind == .voice ? api as? IMAPIClient : nil
                if let voiceAPI {
                    uploadedFile = try await uploadDiagnostic.captureUploadStep {
                        try await voiceAPI.markVoiceMessageUploaded(
                            context: context,
                            fileID: finalizedFileID,
                            conversation: conversation,
                            channelID: channelID,
                            clientMessageID: messageID
                        )
                    }
                } else {
                    uploadedFile = try await uploadDiagnostic.captureUploadStep {
                        try await api.markMessageFileUploaded(
                            context: context,
                            fileID: finalizedFileID,
                            conversation: conversation,
                            channelID: channelID,
                            clientMessageID: messageID
                        )
                    }
                }
                guard ownsOperation() else { return }
                completedFile = uploadedFile
                fileStore.recordAttachmentUploadFinalized(messageID: messageID, file: completedFile)
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_FINALIZED - 修改开始：记录附件服务端 finalize 阶段耗时
                chatBackSendDiagnostic(
                    "app_attachment_upload_finalized",
                    conversationID: conversationID,
                    messageID: messageID,
                    extra: "file=\(Self.shortDebugID(completedFile.id)) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_FINALIZED - 修改结束：记录附件服务端 finalize 阶段耗时
                try await updateUploadOutbox(
                    ticket: durableTicket,
                    messageID: messageID,
                    state: .sending,
                    fileID: completedFile.id,
                    attachmentPhase: "finalized"
                )
                uploadedFileIDForProgressCleanup = completedFile.id
                guard ownsOperation() else {
                    finishStaleAttachmentUpload()
                    return
                }
                setAttachmentFileID(completedFile.id, messageID: messageID, in: conversationID)
                updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
            }
            currentPhase = .send
            try await updateUploadOutbox(
                ticket: durableTicket,
                messageID: messageID,
                state: .awaitingAcknowledgement,
                fileID: completedFile.id,
                attachmentPhase: "message_send"
            )
            updateAttachmentUploadPhase(.send, messageID: messageID, in: conversationID)
            try Task.checkCancellation()
            guard fileStore.hasPendingAttachmentUpload(messageID: messageID), isCurrentRemoteScope(scope) else {
                throw CancellationError()
            }
            let remote: RemoteMessage
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_MESSAGE_SEND - 修改开始：记录附件消息发送阶段开始
            chatBackSendDiagnostic(
                "app_attachment_upload_message_send_begin",
                conversationID: conversationID,
                messageID: messageID,
                extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_MESSAGE_SEND - 修改结束：记录附件消息发送阶段开始
            if pending.kind == .voice {
                guard let durationMS = pending.voiceDurationMS,
                      VoiceMessagePayload.isSendableDurationMS(durationMS) else {
                    throw IMAPIError.server("语音时长无效，请重新录制")
                }
                remote = try await uploadDiagnostic.captureUploadStep {
                    try await api.sendVoice(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        file: completedFile,
                        name: pending.name,
                        mimeType: pending.mimeType,
                        sizeBytes: pending.sizeBytes,
                        durationMS: durationMS,
                        waveform: pending.voiceWaveform,
                        quote: pending.quote,
                        replyContext: pending.replyContext,
                        clientMessageID: messageID
                    )
                }
            } else {
                remote = try await uploadDiagnostic.captureUploadStep {
                    try await api.sendAttachment(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        kind: pending.kind,
                        file: completedFile,
                        name: pending.name,
                        mimeType: pending.mimeType,
                        sizeBytes: pending.sizeBytes,
                        quote: pending.quote,
                        replyContext: pending.replyContext,
                        clientMessageID: messageID
                    )
                }
            }
            guard ownsOperation() else {
                finishStaleAttachmentUpload()
                return
            }
            clearAttachmentProgressKeys([messageID, uploadedFileIDForProgressCleanup, remote.messageID])
            updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
            fileStore.finishAttachmentUpload(messageID: messageID)
            replaceMessageID(localID: messageID, remote: remote, in: conversationID)
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_REMOTE_CONFIRMED - 修改开始：记录远端消息确认与本地替换完成
            chatBackSendDiagnostic(
                "app_attachment_upload_remote_confirmed",
                conversationID: conversationID,
                messageID: messageID,
                extra: "remote=\(Self.shortDebugID(remote.messageID)) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_REMOTE_CONFIRMED - 修改结束：记录远端消息确认与本地替换完成
            if let durableTicket {
                await confirmDurableOutgoing(
                    ticket: durableTicket,
                    clientMessageID: messageID,
                    remote: remote,
                    conversationID: conversationID,
                    scope: scope
                )
            }
            guard ownsOperation() else { return }
            await refreshTenantFilesSnapshot(silent: true)
            guard ownsOperation() else { return }
            if conversation.kind == .group {
                await refreshGroupBundle(groupID: channelID, silent: true)
            }
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_DONE - 修改开始：记录附件上传全链路完成
            chatBackSendDiagnostic(
                "app_attachment_upload_done",
                conversationID: conversationID,
                messageID: messageID,
                extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_DONE - 修改结束：记录附件上传全链路完成
        } catch is CancellationError {
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_CANCELLED - 修改开始：记录附件上传取消耗时
            chatBackSendDiagnostic(
                "app_attachment_upload_cancelled",
                conversationID: conversationID,
                messageID: messageID,
                extra: "phase=\(currentPhase.rawValue) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_CANCELLED - 修改结束：记录附件上传取消耗时
            // Cancellation retires this operation only; explicit user cancellation owns data removal.
            return
        } catch {
            // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_FAILED - 修改开始：记录附件上传失败阶段耗时
            chatBackSendDiagnostic(
                "app_attachment_upload_failed",
                conversationID: conversationID,
                messageID: messageID,
                extra: "phase=\(currentPhase.rawValue) elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
            )
            // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_FAILED - 修改结束：记录附件上传失败阶段耗时
            guard ownsOperation() else {
                finishStaleAttachmentUpload()
                return
            }
            fileStore.finishAttachmentUploadTask(messageID: messageID)
            clearAttachmentProgressKeys([messageID, uploadedFileIDForProgressCleanup])
            updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
            if isNotFriendsError(error) {
                await updateDurableOutbox(ticket: durableTicket, messageID: messageID, state: .failedPermanent)
                guard ownsOperation() else { return }
                fileStore.clearPendingAttachmentUpload(messageID: messageID)
                removeMessage(messageID: messageID, in: conversationID)
                handleNotFriends(for: conversation)
            } else if isSendPolicyForbidden(error) {
                let groupAllMuted = isGroupAllMutedError(error)
                if isGroupMemberMutedError(error) {
                    markGroupMutedForConversation(conversation)
                }
                fileStore.clearPendingAttachmentUpload(
                    messageID: messageID,
                    cleanupSource: !groupAllMuted
                )
                await refreshGroupPolicyAfterSendFailure(conversation, scope: scope)
                guard ownsOperation() else { return }
                await updateDurableOutbox(ticket: durableTicket, messageID: messageID, state: .cancelled)
                guard ownsOperation() else { return }
                handleRemoteError(error, fallback: sendFailureFallback)
                removeMessage(messageID: messageID, in: conversationID)
                if groupAllMuted {
                    pending.onPolicyRejected?()
                }
            } else {
                await updateDurableOutbox(ticket: durableTicket, messageID: messageID, state: .retryWait)
                guard ownsOperation() else { return }
                conversationStore.markAttachmentUploadFailed(
                    messageID: messageID,
                    conversationID: conversationID,
                    failureStatus: currentPhase.failedStatus,
                    failure: uploadDiagnostic.resolvedUploadFailure(error: error)
                )
                await persistConversationSnapshotImmediately(conversationID: conversationID, scope: scope, source: .localMutation)
                guard ownsOperation() else { return }
                toast = attachmentUploadFailureMessage(for: currentPhase, kind: pending.kind)
            }
        }
    }

    private func updateAttachmentUploadPhase(
        _ phase: AttachmentUploadPhase,
        messageID: String,
        in conversationID: String
    ) {
        _ = conversationStore.updateAttachmentUploadStatus(
            phase.rawValue,
            messageID: messageID,
            conversationID: conversationID
        )
    }

    private func attachmentUploadFailureMessage(for phase: AttachmentUploadPhase, kind: MessageKind) -> String {
        let noun = kind == .image ? "图片" : (kind == .voice ? "语音" : "文件")
        switch phase {
        case .config:
            return "\(noun)上传配置获取失败，请重试"
        case .presign:
            return "\(noun)上传凭证获取失败，请重试"
        case .put:
            return "\(noun)内容上传失败，请重试"
        case .finalize:
            return "\(noun)上传确认失败，请重试"
        case .send:
            return "\(noun)已上传，消息提交失败，请重试"
        }
    }

    private func attachmentUploadRetryMessage(for phase: AttachmentUploadPhase?) -> String {
        switch phase {
        case .config:
            return "正在重新获取上传配置"
        case .presign:
            return "正在重新获取上传凭证"
        case .put:
            return "正在重试内容上传"
        case .finalize:
            return "正在重试上传确认"
        case .send:
            return "正在重试消息提交"
        case nil:
            return "正在重试附件上传"
        }
    }

    func attachmentUploadFailureMessage(for message: ChatMessage) -> String? {
        guard message.status == .failed else { return nil }
        let summary = AttachmentUploadPhase.failurePhase(from: message.attachmentUploadStatus)
            .map { attachmentUploadFailureMessage(for: $0, kind: message.kind) }
        guard let failure = message.attachmentUploadFailure else { return summary }
        return "\(summary ?? "附件发送失败，请重试")\n\(failure.detail)"
    }

    func attachmentMeta(kind: MessageKind, mimeType: String, sizeBytes: Int64?) -> String {
        var parts: [String] = []
        if kind == .image {
            parts.append(mimeType.isEmpty ? "图片" : mimeType.uppercased())
        } else if kind == .voice {
            parts.append("语音")
        } else {
            parts.append(mimeType.isEmpty ? "文件" : mimeType)
        }
        if let sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func voiceAttachmentMeta(durationMS: Int, sizeBytes: Int64?) -> String {
        var parts = ["语音"]
        let label = VoiceMessagePayload.durationLabel(durationMS: durationMS)
        if !label.isEmpty {
            parts.append(label)
        }
        if let sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func voiceMessageFileName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "voice-\(UUID().uuidString).m4a"
        }
        let ext = (trimmed as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "\(trimmed).m4a" : trimmed
    }

    func attachmentSystemPreviewCacheIdentity(for message: ChatMessage) -> String? {
        let mediaCategory = attachmentMediaCategory(for: message)
        let fallbackExtension = attachmentFileExtension(for: message, remoteURL: resolvedAttachmentBestPreviewURL(for: message), mediaCategory: mediaCategory)
        return attachmentPersistentCacheKey(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension)
    }

    func attachmentMimeType(from message: ChatMessage) -> String {
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
        if message.kind == .image { return "image/jpeg" }
        if message.kind == .voice { return "audio/mp4" }
        return "application/octet-stream"
    }

    func uploadedFileMetadata(
        from message: ChatMessage,
        fileIDOverride: String? = nil
    ) -> RemoteAvatarFile? {
        let fileID = (fileIDOverride ?? tenantFileID(for: message))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { return nil }
        let mediaCategory = attachmentMediaCategory(for: message)
        let fileName = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteAvatarFile(
            id: fileID,
            fileName: fileName.isEmpty ? "attachment" : fileName,
            mimeType: attachmentMimeType(from: message),
            sizeBytes: Int(message.attachmentSizeBytes ?? 0),
            status: "uploaded",
            uploadStatus: "uploaded",
            previewAvailable: message.attachmentPreviewAvailable,
            downloadAvailable: message.attachmentDownloadAvailable || !message.attachmentDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            previewURL: retainedRemoteAttachmentURL(message.attachmentPreviewURL),
            downloadURL: retainedRemoteAttachmentURL(message.attachmentDownloadURL),
            downloadEndpoint: "/api/tenant/files/\(fileID)/presign-download",
            detailEndpoint: "/api/tenant/files/\(fileID)",
            cacheKey: message.attachmentCacheKey,
            version: message.attachmentVersion,
            checksum: message.attachmentChecksum,
            mediaCategory: mediaCategory,
            fileExtension: message.attachmentExtension,
            thumbnailURL: retainedRemoteAttachmentURL(message.attachmentThumbnailURL),
            posterURL: retainedRemoteAttachmentURL(message.attachmentPosterURL),
            coverURL: retainedRemoteAttachmentURL(message.attachmentCoverURL),
            previewKind: message.attachmentPreviewKind.isEmpty ? previewKind(forMediaCategory: mediaCategory) : message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            width: message.attachmentWidth,
            height: message.attachmentHeight,
            durationSeconds: message.attachmentDurationSeconds
        )
    }

    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：AppState 只保留附件预览状态编排，具体文件/图片处理交给 support builder
    func localAttachmentPreviewResources(messageID: String, name: String, mimeType: String, data: Data, mediaCategory: String) -> LocalAttachmentPreviewResources? {
        _ = mimeType
        return AttachmentPreviewResourceBuilder.dataPreviewResources(
            messageID: messageID,
            name: name,
            data: data,
            mediaCategory: mediaCategory
        )
    }

    private func applyLocalAttachmentPreviewResources(_ localPreview: LocalAttachmentPreviewResources, to message: inout ChatMessage) {
        if let previewURL = localPreview.previewURL {
            message.attachmentPreviewURL = previewURL.absoluteString
            message.attachmentPreviewAvailable = true
        }
        if let downloadURL = localPreview.downloadURL {
            message.attachmentDownloadURL = downloadURL.absoluteString
            message.attachmentDownloadAvailable = true
        }
        if let thumbnailURL = localPreview.thumbnailURL {
            message.attachmentThumbnailURL = thumbnailURL.absoluteString
        }
        message.attachmentWidth = localPreview.width
        message.attachmentHeight = localPreview.height
    }

    private func scheduleOutgoingAttachmentPreviewPreparation(
        messageID: String,
        conversationID: String,
        name: String,
        data: Data?,
        fileURL: URL?,
        mediaCategory: String
    ) {
        let generation = localMessageSessionGeneration
        Task(priority: .utility) { [weak self] in
            let resources = await AttachmentPreviewResourceBuilder.outgoingPreviewResourcesOffMain(
                messageID: messageID,
                name: name,
                data: data,
                fileURL: fileURL,
                mediaCategory: mediaCategory
            )
            guard let resources,
                  let self,
                  self.localMessageSessionGeneration == generation,
                  var message = self.conversationStore.conversation(id: conversationID)?
                    .messages
                    .first(where: { $0.id == messageID }) else { return }
            self.cacheLocalAttachmentResources(resources, messageID: messageID)
            self.applyLocalAttachmentPreviewResources(resources, to: &message)
            self.updateMessageAttachment(message, in: conversationID)
            self.chatBackSendDiagnostic(
                "app_send_attachment_preview_applied",
                conversationID: conversationID,
                messageID: messageID,
                extra: "media=\(mediaCategory)"
            )
        }
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

    func cacheLocalAttachmentResources(_ resources: LocalAttachmentPreviewResources, messageID: String, fileID: String? = nil, cacheIdentity: String? = nil) {
        let keys = [cacheIdentity ?? "", messageID, fileID ?? ""]
            .compactMap(scopedContentCacheKey)
        guard !keys.isEmpty else { return }
        fileStore.cacheLocalAttachmentResources(resources, cacheKeys: keys)
    }

    private func cacheStableLocalAttachmentResources(
        _ resources: LocalAttachmentPreviewResources,
        for message: ChatMessage,
        mediaCategory: String,
        fallbackExtension: String
    ) {
        cacheLocalAttachmentResources(resources, messageID: message.id, fileID: message.attachmentFileID)
        if let cacheIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
            cacheLocalAttachmentResources(
                resources,
                messageID: message.id,
                fileID: message.attachmentFileID,
                cacheIdentity: cacheIdentity
            )
        }
    }

    func cachedLocalAttachmentResources(for message: ChatMessage) -> LocalAttachmentPreviewResources? {
        let mediaCategory = attachmentMediaCategory(for: message)
        let fallbackExtension = attachmentFileExtension(for: message, remoteURL: nil, mediaCategory: mediaCategory)
        if let cacheIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
            if let key = scopedContentCacheKey(cacheIdentity),
               let resources = fileStore.localAttachmentResources(cacheKey: key),
               resources.hasUsableLocalFile {
                return resources
            }
        }
        let fileID = message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for rawKey in [fileID, message.id] {
            guard let key = scopedContentCacheKey(rawKey) else { continue }
            if let resources = fileStore.localAttachmentResources(cacheKey: key),
               resources.hasUsableLocalFile {
                return resources
            }
        }
        let previewURL = URL(string: message.attachmentPreviewURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let downloadURL = URL(string: message.attachmentDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let thumbnailURL = URL(string: message.attachmentThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let resources = LocalAttachmentPreviewResources(
            previewURL: previewURL?.usableLocalFileURL,
            downloadURL: downloadURL?.usableLocalFileURL,
            thumbnailURL: thumbnailURL?.usableLocalFileURL,
            width: message.attachmentWidth,
            height: message.attachmentHeight
        )
        return resources.hasUsableLocalFile ? resources : nil
    }

    func cachedLocalAttachmentURL(for message: ChatMessage, preferPreview: Bool) -> URL? {
        guard let resources = cachedLocalAttachmentResources(for: message) else { return nil }
        let preferred = preferPreview
            ? [resources.previewURL, resources.downloadURL]
            : [resources.downloadURL, resources.previewURL]
        return preferred.compactMap { $0?.usableLocalFileURL }.first
    }

    func cachedLocalAttachmentThumbnailURL(for message: ChatMessage) -> URL? {
        guard let resources = cachedLocalAttachmentResources(for: message) else { return nil }
        return [resources.thumbnailURL, resources.previewURL, resources.downloadURL]
            .compactMap { $0?.usableLocalFileURL }
            .first
    }

    // JHT_MOD_BEGIN ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改开始：本地文件预览生成委托给 support builder
    func localAttachmentPreviewResources(for message: ChatMessage, localURL: URL, mediaCategory: String) -> LocalAttachmentPreviewResources? {
        AttachmentPreviewResourceBuilder.localFilePreviewResources(
            messageID: message.id,
            localURL: localURL,
            mediaCategory: mediaCategory
        )
    }
    // JHT_MOD_END ATTACHMENT_SEND_PREVIEW_BACKGROUND_PERF_20260912 - 修改结束

    func attachmentPersistentCacheKey(for message: ChatMessage, mediaCategory: String, fallbackExtension: String) -> String {
        if let stableIdentity = attachmentStableCacheIdentity(for: message, mediaCategory: mediaCategory, fallbackExtension: fallbackExtension) {
            return stableIdentity
        }
        let primaryID = (message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            ? message.id
            : (message.attachmentFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? message.id)
        let size = message.attachmentSizeBytes.map(String.init) ?? "unknown-size"
        let updated = message.attachmentUploadStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return scopedContentCacheIdentity([
            primaryID,
            size,
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            updated
        ])
    }

    func attachmentStableCacheIdentity(for message: ChatMessage, mediaCategory: String, fallbackExtension: String) -> String? {
        let resource = attachmentResourceComponents(for: message)
        let cacheKey = message.attachmentCacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceComponent: String
        if !resource.fileID.isEmpty {
            resourceComponent = "file_id:\(resource.fileID)"
        } else if !resource.attachmentID.isEmpty {
            resourceComponent = "attachment_id:\(resource.attachmentID)"
        } else if !resource.mediaID.isEmpty {
            resourceComponent = "media_id:\(resource.mediaID)"
        } else if !cacheKey.isEmpty {
            resourceComponent = "cache_key:\(cacheKey)"
        } else {
            return nil
        }
        let version = message.attachmentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = message.attachmentChecksum.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = message.attachmentSizeBytes.map(String.init) ?? ""
        return scopedContentCacheIdentity([
            resourceComponent,
            version.isEmpty ? "" : "version:\(version)",
            checksum.isEmpty ? "" : "checksum:\(checksum)",
            size.isEmpty ? "" : "size:\(size)",
            mediaCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ])
    }

    func scopedContentCacheIdentity(_ parts: [String]) -> String {
        let payload = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ([currentContentCacheScopePrefix()] + payload).joined(separator: "|")
    }

    func scopedContentCacheKey(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let currentScopePrefix = currentContentCacheScopePrefix()
        if trimmed.hasPrefix("scope:") {
            guard trimmed == currentScopePrefix || trimmed.hasPrefix("\(currentScopePrefix)|") else {
                return nil
            }
            return trimmed
        }
        return scopedContentCacheIdentity([trimmed])
    }

    private func currentContentCacheScopePrefix() -> String {
        let scope = contentCacheScopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return scope.isEmpty ? "scope:missing" : "scope:\(scope)"
    }

    func attachmentFileExtension(for message: ChatMessage, remoteURL: URL?, mediaCategory: String) -> String {
        let explicit = message.attachmentExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nameExtension = ((message.attachmentName ?? message.text) as NSString).pathExtension.lowercased()
        let remoteExtension = remoteURL?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let value = [explicit, nameExtension, remoteExtension].first(where: { !$0.isEmpty }) {
            return sanitizedAttachmentFileExtension(value)
        }

        let mimeType = attachmentMimeType(from: message)
        if mimeType.contains("mp4") { return "mp4" }
        if mimeType.contains("quicktime") { return "mov" }
        if mimeType.contains("webm") { return "webm" }
        if mimeType.contains("x-matroska") { return "mkv" }
        if mimeType.contains("jpeg") { return "jpg" }
        if mimeType.contains("png") { return "png" }
        if mimeType.contains("gif") { return "gif" }
        if mimeType.contains("heic") { return "heic" }
        if mimeType.contains("pdf") { return "pdf" }

        switch mediaCategory {
        case "video": return "mp4"
        case "image": return "jpg"
        case "pdf": return "pdf"
        default: return ""
        }
    }

    private func sanitizedAttachmentFileExtension(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = String(rawValue.lowercased().unicodeScalars.filter { allowed.contains($0) })
        return String(sanitized.prefix(8))
    }

    func inferredAttachmentMediaCategory(kind: MessageKind, name: String, mimeType: String) -> String {
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if kind == .voice {
            return "voice"
        }
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

    func previewKind(forMediaCategory category: String) -> String {
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "image": return "image"
        case "video": return "video"
        case "pdf": return "pdf"
        case "voice": return "voice"
        case "audio": return "audio"
        default: return "download"
        }
    }

    private func normalizedContactCardUID(_ value: String?, rejecting displayName: String = "") -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty || normalized != normalizedName else { return nil }
        return normalized
    }

    func contactCardLocalDisplayName(for user: IMUser) -> String {
        remarkPreferredDisplayName(for: user, fallback: contactCardUID(for: user) ?? "未知用户")
    }

    func contactCardExportDisplayName(for user: IMUser) -> String {
        let identifiers = userIdentityCandidates(for: user)
        if let originalName = contactCardOriginalName(matching: identifiers) {
            return originalName
        }
        let remark = contactRemarkValue(matching: identifiers)
        let candidates = [user.name, user.username, user.userID, user.id].filter { candidate in
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && value != remark
        }
        return preferredDisplayName(
            candidates: candidates.map(Optional.some),
            identifiers: identifiers,
            fallback: contactCardUID(for: user) ?? "未知用户"
        )
    }

    private func contactCardDisplayName(from message: ChatMessage) -> String {
        let name = (message.attachmentName ?? message.text)
            .replacingOccurrences(of: "个人名片：", with: "")
            .replacingOccurrences(of: "推荐名片：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未知用户" : name
    }

    func contactCardExportDisplayName(from message: ChatMessage) -> String {
        let fallbackName = contactCardDisplayName(from: message)
        if let contactID = contactCardUID(for: message),
           let originalName = contactCardOriginalName(matching: [contactID]) {
            return originalName
        }
        return fallbackName
    }

    func contactCardUID(for user: IMUser) -> String? {
        let displayName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [user.id, user.userID]
            .compactMap { normalizedContactCardUID($0, rejecting: displayName) }
            .first
    }

    func contactCardUID(for message: ChatMessage) -> String? {
        let displayName = contactCardDisplayName(from: message)
        if let directID = normalizedContactCardUID(message.attachmentMeta, rejecting: displayName) {
            return directID
        }
        let normalizedMeta = message.attachmentMeta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = (contacts + groups.flatMap(\.members)).filter { user in
            user.name == displayName
                || (!normalizedMeta.isEmpty && (user.id == normalizedMeta || user.userID == normalizedMeta))
        }
        let uniqueIDs = Set(candidates.compactMap { contactCardUID(for: $0) })
        return uniqueIDs.count == 1 ? uniqueIDs.first : nil
    }

    func contactCardAvatarURL(for contactID: String) -> String? {
        guard let avatar = user(for: contactID)?.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !avatar.isEmpty else { return nil }
        return avatar
    }

    func isSystemReadOnlyConversation(_ conversation: Conversation) -> Bool {
        if conversation.kind == .system || conversation.title.contains("系统") {
            return true
        }
        guard conversation.kind != .group else {
            return false
        }
        let hasSystemParticipant = conversation.participants.contains { user in
            let normalizedID = user.id.lowercased()
            return normalizedID.contains("system")
                || normalizedID.contains("bot")
                || user.name.contains("系统")
                || user.title.contains("系统")
        }
        return hasSystemParticipant
    }

}

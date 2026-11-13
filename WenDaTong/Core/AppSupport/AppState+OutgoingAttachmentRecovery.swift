import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
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

extension AppState {
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
        for conversation in conversationStore.conversationMessageSnapshots() where conversation.kind != .system {
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

    func canRetryAttachmentUpload(_ message: ChatMessage) -> Bool {
        fileStore.hasPendingAttachmentUpload(messageID: message.id) && (message.kind == .image || message.kind == .file || message.kind == .voice)
    }

    func retryAttachmentUpload(messageID: String, in conversationID: String) {
        guard let ticket = localMessageTicket else {
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            guard !usesProtectedMessageSends else {
                requestOutgoingMessageConfirmation(conversationID)
                return
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    guard !usesProtectedMessageSends else {
                        requestOutgoingMessageConfirmation(conversationID)
                        return
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                    retryClaimedAttachmentUpload(messageID: messageID, in: conversationID, durableTicket: nil)
                    return
                }
                if authority.isAcknowledged {
                    syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
                    return
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                guard authority.state != LocalMessageOutboxState.confirmationRequired.rawValue else {
                    requestOutgoingMessageConfirmation(conversationID)
                    return
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                let claimed = try await messagePersistence.claimOutboxForReplay(
                    ticket: ticket,
                    authorizationGeneration: ticket.sessionGeneration,
                    trigger: .userInitiated,
                    clientMessageID: messageID,
                    limit: 1,
                    holdLegacyUnconfirmedSends: usesProtectedMessageSends // WDT_IOS1_HTTP_ROUTE_V5_20261113
                )
                guard localMessageTicket?.scopeHash == ticket.scopeHash else { return }
                guard claimed.contains(where: { $0.clientMessageID == messageID }) else {
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    let updated = try await messagePersistence.outgoingAuthority(ticket: ticket, clientMessageID: messageID)
                    guard localMessageTicket == ticket else { return }
                    if updated?.state == LocalMessageOutboxState.confirmationRequired.rawValue {
                        requestOutgoingMessageConfirmation(conversationID)
                        return
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("附件当前不可重发")
                    return
                }
                retryClaimedAttachmentUpload(messageID: messageID, in: conversationID, durableTicket: ticket)
            } catch {
                guard localMessageTicket?.scopeHash == ticket.scopeHash else { return }
                conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(error: error))
                scheduleConversationSnapshotCacheWrite(conversationID: conversationID, scope: remoteDataScopeKey(for: apiContext))
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("附件重发准备失败，请稍后重试")
            }
        }
    }

    func retryClaimedAttachmentUpload(
        messageID: String,
        in conversationID: String,
        durableTicket: LocalMessageSessionTicket?
    ) {
        guard fileStore.hasPendingAttachmentUpload(messageID: messageID),
              let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              conversationStore.conversationMessageSnapshot(at: cIndex).messages.contains(where: { $0.id == messageID }) else {
            resendClaimed(messageID: messageID, in: conversationID, durableTicket: durableTicket)
            return
        }
        guard !fileStore.hasAttachmentUploadTask(messageID: messageID) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("附件正在处理中，请勿重复提交")
            return
        }
        if isSystemReadOnlyConversation(conversationStore.conversationMessageSnapshot(at: cIndex)) {
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知仅支持阅读")
            return
        }
        if let message = directSendBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        if let message = localSendPolicyBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            conversationStore.markAttachmentUploadFailed(messageID: messageID, conversationID: conversationID, failure: AttachmentUploadFailure(code: .policy))
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        let failedPhase = conversationStore.conversationMessageSnapshot(at: cIndex).messages
            .first(where: { $0.id == messageID })
            .flatMap { AttachmentUploadPhase.failurePhase(from: $0.attachmentUploadStatus) }
        guard conversationStore.markAttachmentUploadRetrying(messageID: messageID, conversationID: conversationID) else { return }
        scheduleConversationSnapshotCacheWrite(conversationID: conversationID, scope: remoteDataScopeKey(for: apiContext))
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(attachmentUploadRetryMessage(for: failedPhase))
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已取消附件发送")
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

    func isCurrentAttachmentUpload(messageID: String, operationID: UUID, context: IMAPIContext, generation: UInt64) -> Bool {
        !Task.isCancelled && attachmentUploadOperations[messageID]?.id == operationID
            && localMessageSessionGeneration == generation
            && apiContext.isSameAuthAuthority(as: context.authSessionFence)
    }

    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_UPLOADED_WITHOUT_DESCRIPTOR - 修改开始：识别后端已确认上传完成、无需客户端 PUT 的预签名响应
    static func remoteFileIsUploaded(_ file: RemoteAvatarFile) -> Bool {
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

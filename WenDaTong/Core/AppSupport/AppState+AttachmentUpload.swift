import IM4Domain
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
    func uploadPendingAttachment(messageID: String, in conversationID: String, operationID: UUID, context: IMAPIContext, generation: UInt64) async {
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
              let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let conversation = conversationStore.conversationMessageSnapshot(at: cIndex)
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音数据无效，请重新录制")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(gifAllowed ? config.overLimitMessage : GIFAttachmentUploadPolicy.overLimitMessage(config: config))
                return
            }
            let messageUploadedFile = conversationStore.conversationMessageSnapshot(id: conversationID)?
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
                let videoAPI = pending.kind == .file
                    && inferredAttachmentMediaCategory(kind: pending.kind, name: pending.name, mimeType: pending.mimeType) == "video"
                    ? api as? IMAPIClient : nil
                let videoSource: StagedVideoUploadSource?
                if videoAPI != nil, let durableTicket {
                    videoSource = try await messagePersistence.stagedVideoUploadSource(
                        ticket: durableTicket, clientMessageID: messageID, expectedSizeBytes: pending.sizeBytes
                    )
                    guard ownsOperation() else { return }
                } else {
                    videoSource = nil
                }
                var finalizedFileID = checkpoint?.fileID ?? ""
                var preparedFile: RemoteAvatarFile?

                // WDT_IOS1_ATTACHMENT_UPLOAD_ACTOR_20261113_BEGIN
                @MainActor // Keep captured upload state on the same actor as captureUploadStep.
                // WDT_IOS1_ATTACHMENT_UPLOAD_ACTOR_20261113_END
                func putAttachment(_ upload: RemoteSignedUpload) async throws {
                    guard ownsOperation() else { throw CancellationError() }
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
                    if let videoAPI, let videoSource {
                        try await uploadDiagnostic.captureUploadStep {
                            try await videoAPI.uploadVideoAttachmentBinary(
                                context: context, upload: upload, fileURL: videoSource.url, mimeType: pending.mimeType,
                                sizeBytes: pending.sizeBytes, progress: progress
                            )
                        }
                    } else if let fileURL = pending.fileURL {
                        try await uploadDiagnostic.captureUploadStep {
                            try await api.uploadFileBinary(
                                upload: upload,
                                fileURL: fileURL,
                                mimeType: pending.mimeType,
                                sizeBytes: pending.sizeBytes,
                                progress: progress
                            )
                        }
                    } else if let data = pending.data {
                        try await uploadDiagnostic.captureUploadStep {
                            try await api.uploadFileBinary(
                                upload: upload,
                                data: data,
                                mimeType: pending.mimeType,
                                progress: progress
                            )
                        }
                    } else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                    guard ownsOperation() else { throw CancellationError() }
                    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_BINARY_DONE - 修改开始：记录附件二进制上传阶段耗时
                    chatBackSendDiagnostic(
                        "app_attachment_upload_binary_done",
                        conversationID: conversationID,
                        messageID: messageID,
                        extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
                    )
                    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_BINARY_DONE - 修改结束：记录附件二进制上传阶段耗时
                }

                if checkpoint?.putCompleted != true {
                    currentPhase = .presign
                    try await updateUploadOutbox(
                        ticket: durableTicket,
                        messageID: messageID,
                        state: .sending,
                        attachmentPhase: videoSource != nil && !finalizedFileID.isEmpty ? "video_presigned" : "presign"
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
                    } else if let videoAPI, let videoSource {
                        presign = try await uploadDiagnostic.captureUploadStep {
                            try await videoAPI.presignVideoAttachmentUpload(
                                context: context, conversation: conversation, channelID: channelID,
                                clientMessageID: messageID, fileName: pending.name, mimeType: pending.mimeType,
                                sizeBytes: Int(pending.sizeBytes), checksum: videoSource.checksum,
                                transport: .auto, expectedFileID: finalizedFileID
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
                    let chosenTransport = presign.upload?.transport.lowercased() ?? ""
                    let routeLabel = ["accelerated", "standard"].contains(chosenTransport) ? chosenTransport : "unspecified"
                    // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_UPLOAD_PRESIGNED - 修改开始：记录附件预签名阶段耗时
                    chatBackSendDiagnostic(
                        "app_attachment_upload_presigned",
                        conversationID: conversationID,
                        messageID: messageID,
                        extra: "elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: uploadDiagnosticStartedAt))"
                            + (videoSource == nil ? "" : " transport=\(routeLabel)")
                    )
                    // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_UPLOAD_PRESIGNED - 修改结束：记录附件预签名阶段耗时
                    guard !presign.file.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw IMAPIError.server("file_id_missing")
                    }
                    if videoSource != nil, !finalizedFileID.isEmpty, presign.file.id != finalizedFileID {
                        throw IMAPIError.server("video_upload_identity_mismatch")
                    }
                    finalizedFileID = presign.file.id
                    preparedFile = presign.file
                    if videoSource != nil {
                        try await updateUploadOutbox(
                            ticket: durableTicket, messageID: messageID, state: .sending,
                            fileID: finalizedFileID, attachmentPhase: "video_presigned"
                        )
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
                        try await putAttachment(signedUpload)
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
                    let accelerated = videoSource != nil && chosenTransport == "accelerated"
                    fileStore.recordAttachmentUploadPUTCompleted(
                        messageID: messageID, fileID: finalizedFileID, accelerated: accelerated
                    )
                    try await updateUploadOutbox(
                        ticket: durableTicket,
                        messageID: messageID,
                        state: .sending,
                        fileID: finalizedFileID,
                        attachmentPhase: accelerated ? "video_accelerated_uploaded" : "uploaded"
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
                } else if let videoAPI, let videoSource {
                    // WDT_IOS1_ATTACHMENT_UPLOAD_ACTOR_20261113_BEGIN
                    @MainActor // Keep captured upload state on the same actor as captureUploadStep.
                    // WDT_IOS1_ATTACHMENT_UPLOAD_ACTOR_20261113_END
                    func confirmVideo() async throws -> RemoteAvatarFile {
                        guard ownsOperation(),
                              let checkpoint = fileStore.attachmentUploadCheckpoint(messageID: messageID) else {
                            throw CancellationError()
                        }
                        currentPhase = .finalize
                        updateAttachmentUploadPhase(.finalize, messageID: messageID, in: conversationID)
                        updateAttachmentProgress(nil, messageID: messageID, in: conversationID)
                        return try await uploadDiagnostic.captureUploadStep {
                            try await videoAPI.confirmRoutedVideoAttachmentUpload(
                                context: context, conversation: conversation, channelID: channelID, clientMessageID: messageID,
                                fileID: finalizedFileID, sizeBytes: pending.sizeBytes, mimeType: pending.mimeType,
                                checksum: videoSource.checksum, preparedFile: preparedFile,
                                verificationSelected: checkpoint.videoVerificationSelected
                            ) {
                                try await updateUploadOutbox(
                                    ticket: durableTicket, messageID: messageID, state: .sending,
                                    fileID: finalizedFileID, attachmentPhase: checkpoint.videoVerificationPhase
                                )
                                fileStore.recordVideoUploadVerificationSelected(messageID: messageID)
                            }
                        }
                    }
                    do {
                        uploadedFile = try await confirmVideo()
                    } catch let missing as VideoAttachmentObjectMissing {
                        guard ownsOperation(),
                              let state = fileStore.attachmentUploadCheckpoint(messageID: messageID),
                              state.accelerated, !state.standardFallbackUsed,
                              missing.retryAfterSeconds < 600 else { throw missing }
                        if missing.retryAfterSeconds > 0 {
                            try await Task.sleep(nanoseconds: UInt64(missing.retryAfterSeconds) * 1_000_000_000)
                        }
                        // Reserve the only fallback durably before a signature or PUT can escape.
                        try await updateUploadOutbox(
                            ticket: durableTicket, messageID: messageID, state: .sending,
                            fileID: finalizedFileID, attachmentPhase: state.videoVerificationSelected
                                ? "video_fallback_verifying" : "video_standard_fallback"
                        )
                        fileStore.recordAttachmentUploadStandardFallback(messageID: messageID, fileID: finalizedFileID)
                        currentPhase = .presign
                        updateAttachmentUploadPhase(.presign, messageID: messageID, in: conversationID)
                        let fallback = try await uploadDiagnostic.captureUploadStep {
                            try await videoAPI.presignVideoAttachmentUpload(
                                context: context, conversation: conversation, channelID: channelID,
                                clientMessageID: messageID, fileName: pending.name, mimeType: pending.mimeType,
                                sizeBytes: Int(pending.sizeBytes), checksum: videoSource.checksum,
                                transport: .standard, expectedFileID: finalizedFileID
                            )
                        }
                        guard ownsOperation() else { return }
                        guard fallback.file.id == finalizedFileID, fallback.file.status == "prepared",
                              let upload = fallback.upload, upload.transport.lowercased() == "standard" else {
                            throw IMAPIError.server("video_upload_fallback_identity_mismatch")
                        }
                        preparedFile = fallback.file
                        try await putAttachment(upload)
                        uploadedFile = try await confirmVideo()
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
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    try await withDurableOutgoingSend(ticket: durableTicket, messageID: messageID) {
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
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                }
            } else {
                remote = try await uploadDiagnostic.captureUploadStep {
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    try await withDurableOutgoingSend(ticket: durableTicket, messageID: messageID) {
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
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            if await retainUnconfirmedOutgoing(error, ticket: durableTicket, messageID: messageID,
                                               conversationID: conversationID, scope: scope) { return }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(attachmentUploadFailureMessage(for: currentPhase, kind: pending.kind))
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

    func attachmentUploadRetryMessage(for phase: AttachmentUploadPhase?) -> String {
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

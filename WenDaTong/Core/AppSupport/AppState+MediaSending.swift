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
              let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_ATTACHMENT_LOG_ENTER - 修改开始：记录附件发送入口，不输出文件名
        chatBackSendDiagnostic(
            "app_send_attachment_enter",
            conversationID: conversationID,
            extra: "kind=\(kind.rawValue) size_bytes=\(sizeBytes ?? -1) data_bytes=\(data?.count ?? -1) file_backed=\(fileURL != nil) auto_start=\(automaticallyStartUpload) messages=\(conversationStore.conversationMessageSnapshot(at: cIndex).messages.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_ATTACHMENT_LOG_ENTER - 修改结束：记录附件发送入口，不输出文件名
        if isSystemReadOnlyConversation(conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知仅支持阅读")
            return false
        }
        if let message = directSendBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return false
        }
        let fileSizeBytes = fileURL.flatMap { PendingAttachmentFileStore.fileSize(at: $0) }
        guard data != nil || fileSizeBytes != nil else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(kind == .image ? "图片数据读取失败，请重新选择后发送" : "文件数据读取失败，请重新选择后发送")
            return false
        }
        guard kind != .image || data?.isEmpty == false || (fileSizeBytes ?? 0) > 0 else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("图片数据读取失败，请重新选择后发送")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_attachment")
        var normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (kind == .image ? "图片消息.jpg" : "未命名文件") : name
        let actualSizeBytes = data.map { Int64($0.count) } ?? fileSizeBytes ?? 0
        guard sizeBytes == nil || sizeBytes == actualSizeBytes else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("文件大小已变化，请重新选择后发送")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(GIFAttachmentUploadPolicy.overLimitMessage(config: fileUploadConfig))
            return false
        } catch {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(GIFAttachmentUploadPolicy.invalidMessage)
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(GIFAttachmentUploadPolicy.overLimitMessage(config: fileUploadConfig))
            return false
        }
        let kind: MessageKind = isGIF ? .image : kind
        let mimeType = isGIF ? "image/gif" : mimeType
        if isGIF, (normalizedName as NSString).pathExtension.lowercased() != "gif" {
            normalizedName = (normalizedName as NSString).deletingPathExtension + ".gif"
        }
        guard fileUploadConfig.allowsUpload(sizeBytes: effectiveSizeBytes) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(fileUploadConfig.overLimitMessage)
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
            unreadBy: conversationStore.conversationMessageSnapshot(at: cIndex).participants.prefix(3).map { ReadReceipt(id: "attachment_pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(kind == .image ? "图片已加入发送队列" : "文件已加入发送队列")
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
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        if isSystemReadOnlyConversation(conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知仅支持阅读")
            return false
        }
        if let message = directSendBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return false
        }
        if let message = localSendPolicyBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return false
        }
        guard !VoiceMessagePayload.isTooShort(durationMS: durationMS) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("说话时间太短")
            return false
        }
        guard VoiceMessagePayload.isSendableDurationMS(durationMS) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音时长无效，请重新录制")
            return false
        }
        guard !data.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音数据读取失败，请重新录制")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_voice")
        let normalizedName = voiceMessageFileName(name)
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "audio/mp4" : mimeType
        guard normalizedMimeType.lowercased().hasPrefix("audio/") else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音格式无效，请重新录制")
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
            unreadBy: conversationStore.conversationMessageSnapshot(at: cIndex).participants.prefix(3).map { ReadReceipt(id: "voice_pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("语音已加入发送队列")
        startAttachmentUploadTask(messageID: message.id, in: conversationID)
        return true
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

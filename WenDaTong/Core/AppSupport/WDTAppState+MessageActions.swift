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

// MARK: - Message Actions

enum OwnMessageDeletion: Equatable {
    case sent
    case failed

    static func available(for message: ChatMessage, isCurrentSender: Bool) -> Self? {
        guard isCurrentSender, message.isOutgoing,
              message.kind != .system, !message.isRTCCallRecordMessage,
              !message.isDeletedLocally,
              !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if message.status == .failed, message.channelSeq == 0 { return .failed }
        if message.channelSeq > 0, !message.id.hasPrefix("local_"),
           message.status == .sent || message.status == .read { return .sent }
        return nil
    }
}

extension AppState {
    func deleteConversation(_ conversationID: String) {
        guard let targetConversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              conversationListSupportsMutableActions(targetConversation.conversation) else { return }
        for message in targetConversation.messages {
            invalidateIndexedMediaCache(for: message, state: .authorizationStale)
        }
        guard let removed = conversationStore.deleteConversation(conversationID: conversationID) else { return }
        if apiContext.hasIMSession {
            let scope = remoteDataScopeKey(for: apiContext)
            hideConversationLocally(removed, scope: scope)
            if let ticket = localMessageTicket {
                let mediaContext = mediaCacheScopeContext
                Task {
                    await deletePersistedConversationAndMedia(
                        ticket: ticket,
                        conversationID: conversationID,
                        context: mediaContext
                    )
                }
            }
            scheduleRemoteSnapshotCacheWrite(scope: scope)
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已删除会话 \(removed.title)")
    }

    func resend(messageID: String, in conversationID: String) {
        guard let ticket = localMessageTicket else {
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            guard !usesProtectedMessageSends else {
                requestOutgoingMessageConfirmation(conversationID)
                return
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
            resendClaimed(messageID: messageID, in: conversationID, durableTicket: nil)
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
                    resendClaimed(messageID: messageID, in: conversationID, durableTicket: nil)
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息当前不可重发")
                    return
                }
                resendClaimed(messageID: messageID, in: conversationID, durableTicket: ticket)
            } catch {
                markMessageFailed(messageID: messageID, in: conversationID)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息重发准备失败，请稍后重试")
            }
        }
    }

    func resendClaimed(
        messageID: String,
        in conversationID: String,
        durableTicket claimedTicket: LocalMessageSessionTicket?
    ) {
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversationStore.conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == messageID }) else { return }
        let originalMessage = conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex]
        if (originalMessage.kind == .file || originalMessage.kind == .image || originalMessage.kind == .voice),
           fileStore.hasPendingAttachmentUpload(messageID: messageID) {
            retryClaimedAttachmentUpload(
                messageID: messageID,
                in: conversationID,
                durableTicket: claimedTicket
            )
            return
        }
        let resolvedContactID: String?
        if originalMessage.kind == .contactCard {
            guard let contactID = contactCardUID(for: originalMessage) else {
                conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该联系人缺少用户ID，暂不能发送名片")
                return
            }
            resolvedContactID = contactID
            conversationStore.setContactCardAttachmentMeta(messageID: messageID, conversationID: conversationID, contactID: contactID)
        } else {
            resolvedContactID = nil
        }
        let resolvedAttachmentFile: RemoteAvatarFile?
        if originalMessage.kind == .file || originalMessage.kind == .image || originalMessage.kind == .voice {
            guard let file = uploadedFileMetadata(from: originalMessage) else {
                conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("附件缺少上传文件ID，请重新选择后发送")
                return
            }
            resolvedAttachmentFile = file
        } else {
            resolvedAttachmentFile = nil
        }
        if isSystemReadOnlyConversation(conversationStore.conversationMessageSnapshot(at: cIndex)) {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知仅支持阅读")
            return
        }
        if let message = directSendBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        if let message = localSendPolicyBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard let message = conversationStore.prepareMessageForResend(
            messageID: messageID,
            conversationID: conversationID,
            readBy: [
                ReadReceipt(id: "me_read", user: currentUser, device: "iPhone", time: "刚刚")
            ]
        ) else { return }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在重新发送")
        let conversation = conversationStore.conversationMessageSnapshot(at: cIndex)
        let channelID = remoteChannelID(for: conversation)
        Task {
            var durableTicket: LocalMessageSessionTicket? = claimedTicket
            do {
                if durableTicket == nil {
                    durableTicket = try await enqueueDurableOutgoing(
                        messageID: message.id,
                        conversationID: conversationID,
                        operationKind: "resend_\(message.kind.rawValue)",
                        context: context,
                        scope: scope
                    )
                }
                let remote: RemoteMessage
                if message.kind == .voice {
                    let durationMS = VoiceMessagePayload.decodedDurationMS(message.attachmentDurationSeconds) // WDT_IOS1_SAFE_NUMERIC_20261023
                        ?? VoiceMessagePayload.minDurationMS
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                        try await api.sendVoice(
                            context: context,
                            conversation: conversation,
                            channelID: channelID,
                            file: resolvedAttachmentFile!,
                            name: message.attachmentName ?? message.text,
                            mimeType: attachmentMimeType(from: message),
                            sizeBytes: message.attachmentSizeBytes,
                            durationMS: durationMS,
                            waveform: message.voiceWaveform,
                            quote: message.quote,
                            replyContext: message.replyContext,
                            clientMessageID: message.id
                        )
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                } else if message.kind == .file || message.kind == .image {
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                        try await api.sendAttachment(
                            context: context,
                            conversation: conversation,
                            channelID: channelID,
                            kind: message.kind,
                            file: resolvedAttachmentFile!,
                            name: message.attachmentName ?? message.text,
                            mimeType: attachmentMimeType(from: message),
                            sizeBytes: message.attachmentSizeBytes,
                            quote: message.quote,
                            replyContext: message.replyContext,
                            clientMessageID: message.id
                        )
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                } else if message.kind == .contactCard {
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                        try await api.sendContactCard(
                            context: context,
                            conversation: conversation,
                            channelID: channelID,
                            contactID: resolvedContactID ?? message.attachmentMeta ?? "",
                            contactName: contactCardExportDisplayName(from: message),
                            contactAvatar: (resolvedContactID ?? message.attachmentMeta).flatMap { contactCardAvatarURL(for: $0) },
                            quote: message.quote,
                            clientMessageID: message.id
                        )
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                } else if message.isStickerMessage {
                    guard let stickerSnapshot = message.stickerSnapshot else {
                        conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("表情资源缺少快照，暂不能重发")
                        return
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                        try await api.sendSticker(
                            context: context,
                            conversation: conversation,
                            channelID: channelID,
                            sticker: stickerSnapshot,
                            quote: message.quote,
                            replyContext: message.replyContext,
                            clientMessageID: message.id
                        )
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                } else {
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                    remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                        try await api.sendText(context: context, conversation: conversation, channelID: channelID, text: message.text, quote: message.quote, replyContext: message.replyContext, clientMessageID: message.id, mentionAll: message.mentionAll, mentionedUsers: message.mentionedUsers)
                    }
                    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                }
                guard isCurrentRemoteScope(scope) else { return }
                if message.isStickerMessage {
                    removeMessage(messageID: message.id, in: conversationID)
                    applyRemoteMessages(
                        [remote],
                        channelID: remote.channelID.isEmpty ? channelID : remote.channelID,
                        channelType: remote.channelType.isEmpty ? apiChannelType(for: conversation.kind) : remote.channelType
                    )
                } else {
                    replaceMessageID(localID: message.id, remote: remote, in: conversationID)
                }
                if let durableTicket {
                    await confirmDurableOutgoing(
                        ticket: durableTicket,
                        clientMessageID: message.id,
                        remote: remote,
                        conversationID: conversationID,
                        scope: scope
                    )
                }
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                if await retainUnconfirmedOutgoing(error, ticket: durableTicket, messageID: message.id,
                                                   conversationID: conversationID, scope: scope) { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                markMessageFailed(messageID: message.id, in: conversationID)
                if isSendPolicyForbidden(error) {
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(conversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(conversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                }
                handleRemoteError(error, fallback: "消息重发失败")
            }
        }
    }

    func copyMessage(_ message: ChatMessage) {
        UIPasteboard.general.string = message.text
        syncIOSRiskTelemetrySession()
        let conversation = conversationStore.conversationMessageSnapshots().first { conversation in
            conversation.messages.contains(where: { $0.id == message.id })
        }
        iosRiskTelemetry.recordClipboardCopy(
            characterCount: message.text.count,
            resourceType: "message",
            resourceID: message.id,
            channelType: conversation.map { apiChannelType(for: $0.kind) },
            channelID: conversation.map { remoteChannelID(for: $0) }
        )
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已复制消息内容")
    }

    // WDT_RECEIPT_DETAIL_SCOPE_20261023_BEGIN
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

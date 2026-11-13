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

private struct RetryableMessageSendAuthorizationError: Error {}

extension AppState {
    private func shouldSyncConversationAfterSendConfirmation(_ remote: RemoteMessage) -> Bool {
        remote.channelSeq <= 0 || !isRealtimeConnected
    }

    private func sendTextRecoveringUncertainOutcomeOnce(
        context: IMAPIContext,
        scope: String,
        conversation: ConversationMessageSnapshot,
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
            } catch let uncertain as MessageSendOutcomeUncertainError {
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                if uncertain.requiresReadback || usesProtectedMessageSends {
                    throw uncertain
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
              let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else { return false }
        // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_LOG_ENTER - 修改开始：记录文本发送入口，不输出正文
        chatBackSendDiagnostic(
            "app_send_text_enter",
            conversationID: conversationID,
            extra: "text_len=\(trimmed.count) mention_all=\(mentionAll) mentions=\(mentionedUsers.count) messages=\(conversationStore.conversationMessageSnapshot(at: cIndex).messages.count)"
        )
        // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_LOG_ENTER - 修改结束：记录文本发送入口，不输出正文
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
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
            unreadBy: conversationStore.conversationMessageSnapshot(at: cIndex).participants.prefix(3).map { ReadReceipt(id: "pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
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
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                let remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                    try await sendTextRecoveringUncertainOutcomeOnce(
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
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息发送失败，可点击重发")
            } catch let uncertain as MessageSendOutcomeUncertainError {
                // JHT_MOD_BEGIN CHAT_BACK_STUCK_DIAG_BEGIN_SEND_TEXT_UNCERTAIN - 修改开始：记录文本发送状态未确认耗时
                chatBackSendDiagnostic(
                    "app_send_text_task_failed",
                    conversationID: conversationID,
                    messageID: message.id,
                    extra: "reason=uncertain elapsed_ms=\(Self.chatBackDiagnosticElapsedMS(since: sendTextTaskStartedAt))"
                )
                // JHT_MOD_END CHAT_BACK_STUCK_DIAG_END_SEND_TEXT_UNCERTAIN - 修改结束：记录文本发送状态未确认耗时
                guard isCurrentRemoteScope(scope) else { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                if await retainUnconfirmedOutgoing(uncertain, ticket: durableTicket, messageID: message.id,
                                                   conversationID: conversationID, scope: scope) { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .uncertain, uncertain: true)
                markMessageFailed(messageID: message.id, in: conversationID)
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息发送状态未确认，可点击重发")
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                if await retainUnconfirmedOutgoing(error, ticket: durableTicket, messageID: message.id,
                                                   conversationID: conversationID, scope: scope) { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

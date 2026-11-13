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
    func forwardMessage(_ message: ChatMessage) {
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message.isForwardSupported ? "请选择要转发到的会话" : "该消息类型暂不支持转发")
    }

    func forwardMessage(_ message: ChatMessage, to target: ConversationMessageSnapshot) {
        if let reason = messageActionPolicyUnavailableReason(.forward) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        guard message.isForwardSupported else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该消息类型暂不支持转发")
            return
        }
        guard target.kind == .direct || target.kind == .group else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("只能转发到单聊或群聊")
            return
        }
        let targetChannelID = remoteChannelID(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetChannelID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("目标会话不可用，请刷新后重试")
            return
        }
        let targetChannelType = apiChannelType(for: target.kind)
        let clientMessageID = "ios-forward-\(UUID().uuidString)"
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        Task {
            do {
                let remote = try await api.forwardMessage(
                    context: context,
                    messageID: message.id,
                    targetChannelID: targetChannelID,
                    targetChannelType: targetChannelType,
                    clientMessageID: clientMessageID
                )
                guard isCurrentRemoteScope(scope) else { return }
                applyRemoteMessages(
                    [remote],
                    channelID: remote.channelID.isEmpty ? targetChannelID : remote.channelID,
                    channelType: remote.channelType.isEmpty ? targetChannelType : remote.channelType
                )
                syncConversationMessagesIfNeeded(target.id, force: true, silent: true)
                _ = await refreshRemoteSnapshot(silent: true, force: true)
                guard isCurrentRemoteScope(scope) else { return }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已转发到「\(target.title)」")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "消息转发失败")
            }
        }
    }

    func addReaction(_ emoji: String, to messageID: String, in conversationID: String) {
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversationStore.conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex]
        guard message.status != .failed, message.status != .sending else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息发送成功后才能回应")
            return
        }
        let conversation = conversationStore.conversationMessageSnapshot(at: cIndex)
        if let message = localSendPolicyBlockedMessage(for: conversation) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let operatorUID = context.imUID ?? currentUser.id
        let wasAlreadyReactedByMe = message.reactions.contains { reaction in
            reaction.emoji == emoji && reaction.reactedByMe
        }
        let action = wasAlreadyReactedByMe ? "remove" : "add"
        applyMessageReaction(messageID: messageID, emoji: emoji, operatorUID: operatorUID, action: action)
        Task {
            do {
                if let ticket = localMessageTicket,
                   let throughSeq = try? await messagePersistence.recordAckDesired(
                       ticket: ticket,
                       channelKey: channelID,
                       type: "read",
                       desiredSeq: latestReadableSequence(in: conversation)
                   ),
                   throughSeq > 0 {
                    _ = try? await api.readAck(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        throughSeq: throughSeq
                    )
                }
                let response = try await api.reactMessage(context: context, messageID: messageID, emoji: emoji, action: action)
                guard isCurrentRemoteScope(scope) else { return }
                if !response.readReceipts.isEmpty {
                    applyRemoteReadReceipts(response.readReceipts, channelID: channelID)
                }
                if let extra = response.extra {
                    applyRemoteMessageExtra(extra, fromRealtime: false)
                } else {
                    applyMessageReaction(messageID: messageID, emoji: emoji, operatorUID: operatorUID, action: action)
                }
                if let session = currentMessageSidecarSyncSession() {
                    await syncConversationSidecars(channelID: channelID, channelType: channelType, session: session)
                    guard isCurrentRemoteScope(scope) else { return }
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(action == "remove" ? "已取消表情回应 \(emoji)" : "已添加表情回应 \(emoji)")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                applyMessageReaction(messageID: messageID, emoji: emoji, operatorUID: operatorUID, action: action == "remove" ? "add" : "remove")
                if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                    return
                }
                if isSendPolicyForbidden(error) {
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(conversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(conversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                    handleRemoteError(error, fallback: "表情回应失败")
                    return
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("表情回应失败，请稍后重试")
            }
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

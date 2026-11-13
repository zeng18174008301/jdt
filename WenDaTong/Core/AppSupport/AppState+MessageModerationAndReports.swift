import IM4Features
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
    func canAdminDeleteMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              conversation.kind == .group,
              let group = groupForConversation(conversation) else { return false }
        guard canManageGroup(group) else { return false }
        guard message.kind != .system,
              message.status != .sending,
              message.status != .failed,
              message.status != .recalled,
              !message.isDeletedLocally else { return false }
        return !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func adminDeleteMessageForAll(messageID: String, in conversationID: String) {
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversationStore.conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == messageID }) else { return }
        let conversation = conversationStore.conversationMessageSnapshot(at: cIndex)
        let message = conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex]
        guard canAdminDeleteMessage(message, in: conversationID) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅群主或管理员可以对全员删除消息")
            return
        }
        let groupID = remoteChannelID(for: conversation)
        guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群聊不存在或已删除")
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let channelType = apiChannelType(for: conversation.kind)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        guard fileUploadConfig.groupAdminDeleteMessageEnabled else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前企业未开通")
            return
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在删除消息")
        Task {
            do {
                try await api.adminDeleteGroupMessage(context: context, groupID: groupID, messageID: messageID)
                guard isCurrentRemoteScope(scope) else { return }
                if applyAdminDeletedMessage(messageID: messageID, conversationID: conversationID) {
                    scheduleRemoteSnapshotCacheWrite(scope: scope)
                }
                await syncMessageExtrasForConversation(channelID: groupID, channelType: channelType)
                guard isCurrentRemoteScope(scope) else { return }
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(shouldShowMessageProcessingNotices ? "已对全员删除该消息" : nil)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if let message = adminDeleteFailureMessage(error) {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                } else {
                    handleRemoteError(error, fallback: "删除消息失败")
                }
            }
        }
    }

    private func adminDeleteFailureMessage(_ error: Error) -> String? {
        let codes: [String]
        switch error {
        case IMAPIError.businessForbidden(let code, _, let envelope):
            codes = [code, envelope?.code, envelope?.reasonCode].compactMap { $0 }
        case IMAPIError.conflict(let code, _):
            codes = [code]
        case IMAPIError.forbidden(_):
            return "无权限删除该消息"
        default:
            return nil
        }
        let normalizedCodes = codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if normalizedCodes.contains(where: { ["feature_not_enabled", "group_admin_delete_message_not_enabled"].contains($0) }) {
            return "当前企业未开通"
        }
        if normalizedCodes.contains(where: { ["permission_denied", "admin_delete_forbidden", "message_admin_delete_forbidden"].contains($0) }) {
            return "无权限删除该消息"
        }
        if normalizedCodes.contains(where: { ["message_not_found", "not_found", "message_not_visible", "message_invisible"].contains($0) }) {
            return "消息不存在或已不可见"
        }
        if normalizedCodes.contains(where: { ["message_already_deleted", "duplicate"].contains($0) }) {
            return "该消息已删除"
        }
        return nil
    }

    private func groupForConversation(_ conversation: ConversationMessageSnapshot) -> GroupInfo? {
        let channelID = remoteChannelID(for: conversation)
        return groups.first { group in
            group.id == conversation.id
                || group.id == channelID
                || group.name == conversation.title
        }
    }

    @discardableResult
    func applyAdminDeletedMessage(
        messageID: String,
        conversationID: String? = nil,
        authorityVersion: String? = nil
    ) -> Bool {
        let cachedMessage = conversationStore.conversationMessageSnapshots().lazy.compactMap { conversation in
            conversation.messages.first(where: { $0.id == messageID })
        }.first
        let didApply = conversationStore.applyAdminDeletedMessage(
            messageID: messageID,
            conversationID: conversationID,
            channelIDForConversation: { remoteChannelID(for: $0) }
        )
        if didApply || authorityVersion != nil, let context = mediaCacheScopeContext {
            invalidateIndexedMediaCache(
                messageID: messageID,
                state: .deleted,
                authorityVersion: authorityVersion ?? String(max(cachedMessage?.editRevision ?? 0, 0)),
                context: context
            )
        }
        return didApply
    }

    func messageRecallUnavailableReason(_ message: ChatMessage, policy: MessageActionsPolicy? = nil) -> String? { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        if let reason = messageActionPolicyUnavailableReason(.recall, policy: policy) { return reason } // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        guard message.isOutgoing else { return "只能撤回自己发送的消息" }
        guard message.status != .recalled else { return "消息已撤回" }
        guard message.status != .failed else { return "消息未发送成功，无需撤回" }
        let maxMinutes = fileUploadConfig.messageRecallMaxMinutes
        guard maxMinutes > 0 else { return "已超过当前企业最长时间" }
        guard let createdAt = effectiveCreatedAt(for: message) else { return nil }
        if Date().timeIntervalSince(createdAt) > Double(maxMinutes) * 60 {
            return "已超过当前企业最长时间"
        }
        return nil
    }

    func toggleMessagePinned(messageID: String, in conversationID: String) {
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              let currentValue = conversationStore.messagePinnedState(messageID: messageID, conversationID: conversationID) else { return }
        let nextValue = !currentValue
        let conversation = conversationStore.conversationMessageSnapshot(at: cIndex)
        let channelID = remoteChannelID(for: conversation)
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        Task {
            do {
                let response = try await api.pinMessage(context: context, messageID: messageID, pinned: nextValue)
                guard isCurrentRemoteScope(scope) else { return }
                if let extra = response.extra {
                    applyRemoteMessageExtra(extra, fromRealtime: false)
                }
                if !response.readReceipts.isEmpty {
                    applyRemoteReadReceipts(response.readReceipts, channelID: channelID)
                }
                conversationStore.setMessagePinned(messageID: messageID, conversationID: conversationID, pinned: nextValue)
                _ = await refreshRemoteSnapshot(silent: true, force: true)
                guard isCurrentRemoteScope(scope) else { return }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nextValue ? "已置顶单条消息" : "已取消消息置顶")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                    return
                }
                handleRemoteError(error, fallback: nextValue ? "置顶消息失败" : "取消置顶失败")
            }
        }
    }

    func refreshPinnedMessages(for conversationID: String, silent: Bool = true) {
        guard let index = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              conversationStore.conversationMessageSnapshot(at: index).kind == .group else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else { return }
        let channelID = remoteChannelID(for: conversationStore.conversationMessageSnapshot(at: index))
        guard !channelID.isEmpty else { return }
        let keyContext = conversationStore.pinnedMessagesRefreshKeyContext(
            tenantID: context.tenantID,
            imUID: context.imUID,
            conversationID: conversationID,
            channelID: channelID
        )
        let refreshKey = keyContext.refreshKey
        guard conversationStore.beginPinnedMessagesRefresh(refreshKey: refreshKey) else { return }
        Task {
            defer {
                conversationStore.finishPinnedMessagesRefresh(refreshKey: refreshKey)
            }
            do {
                let remotes = try await api.groupPinnedMessages(context: context, groupID: channelID)
                guard isCurrentRemoteScope(scope) else { return }
                guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
                let entries = pinnedMessageSnapshotEntries(from: remotes, participants: conversation.participants)
                conversationStore.applyPinnedMessageSnapshot(entries, conversationID: conversationID)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if silent {
                    logSyncEndpointFailure("/api/im/groups/\(channelID)/pinned-messages", error: error)
                } else {
                    if let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
                       shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(groupHistoryLimitedMessage)
                        return
                    }
                    handleRemoteError(error, fallback: "刷新置顶消息失败")
                }
            }
        }
    }

    func toggleMessageFavorite(messageID: String, in conversationID: String) {
        guard let currentValue = conversationStore.messageFavoritedState(messageID: messageID, conversationID: conversationID) else { return }
        let nextValue = !currentValue
        Task {
            await setMessageFavorite(messageID: messageID, favorited: nextValue)
        }
    }

    func reportMessage(messageID: String, in conversationID: String, reason: String) {
        Task {
            _ = await submitMessageReport(messageID: messageID, in: conversationID, reason: reason, description: reason)
        }
    }

    @discardableResult
    func submitMessageReport(messageID: String, in conversationID: String, reason: String, description: String) async -> Bool {
        switch await submitMessageReportDetailed(messageID: messageID, in: conversationID, reason: reason, description: description) {
        case .submitted, .alreadyReported:
            return true
        case .failed:
            return false
        }
    }

    func lookupMessageReport(messageID: String, in conversationID: String) async -> RemoteMessageReport? {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty, !normalizedMessageID.hasPrefix("local_") else { return nil }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession,
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              let targetMessage = conversation.messages.first(where: { $0.id == normalizedMessageID }),
              !isCurrentMessageSender(targetMessage.senderId) else {
            return nil
        }
        do {
            let result = try await api.lookupMessageReport(context: context, messageID: normalizedMessageID)
            guard isCurrentRemoteScope(scope) else { return nil }
            guard result.reported else { return nil }
            return result.report
        } catch {
            return nil
        }
    }

    func submitMessageReportDetailed(messageID: String, in conversationID: String, reason: String, description: String) async -> MessageReportSubmissionResult {
        let normalizedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageID.isEmpty,
              !normalizedMessageID.hasPrefix("local_") else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该消息暂不能举报")
            return .failed
        }
        guard MessageReportCategory.allowedReasons.contains(normalizedReason) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请选择举报分类")
            return .failed
        }
        guard !normalizedDescription.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入举报理由")
            return .failed
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return .failed
        }
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              let targetMessage = conversation.messages.first(where: { $0.id == normalizedMessageID }) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息不存在或已刷新")
            return .failed
        }
        guard !isCurrentMessageSender(targetMessage.senderId) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("不能举报自己发送的消息")
            return .failed
        }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        do {
            let report = try await api.reportMessage(
                context: context,
                messageID: normalizedMessageID,
                channelID: channelID,
                channelType: channelType,
                reason: normalizedReason,
                description: normalizedDescription
            )
            guard isCurrentRemoteScope(scope) else { return .failed }
            if report.alreadyReported || report.readOnly {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已举报成功")
                return .alreadyReported(report)
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("举报已提交")
            return .submitted(report)
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed }
            handleRemoteError(error, fallback: "提交举报失败")
            return .failed
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

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
    var messageEditCurrentConversationID: String? {
        activeRealtimeConversationID
    }

    private func messageEditResponseText(_ payload: [String: JSONValue]) -> String {
        if let nested = payload["payload"]?.objectValue {
            let text = payloadString(nested, ["text", "content", "body"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return payloadString(payload, ["text", "content", "body"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func messageEditResponseBelongsToConversation(
        channelID: String,
        channelType: String,
        conversation: ConversationMessageSnapshot
    ) -> Bool {
        let expectedType = apiChannelType(for: conversation.kind)
        let candidateType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? expectedType
            : channelType
        let expectedChannelID = normalizedRemoteChannelID(
            remoteChannelID(for: conversation),
            channelType: expectedType
        )
        let candidateChannelID = normalizedRemoteChannelID(channelID, channelType: candidateType)
        return !expectedChannelID.isEmpty
            && !candidateChannelID.isEmpty
            && candidateChannelID == expectedChannelID
            && conversationKind(from: candidateType, channelID: candidateChannelID) == conversation.kind
    }

	@discardableResult
	func editMessage(messageID: String, in conversationID: String, newText: String) async -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("编辑内容不能为空")
			return false
		}
		guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
		      let message = conversation.messages.first(where: { $0.id == messageID }) else {
			/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息不存在或已不在当前会话")
			return false
		}
		if let reason = messageEditUnavailableReason(message) {
			/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
			return false
		}
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
			return false
        }
		let clientEditID = UUID().uuidString.lowercased()
		let expectedRevision = max(0, message.editRevision)
		/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在保存编辑")
		do {
			let response: RemoteExtraResponse
			do {
				response = try await api.editMessage(
					context: context,
					messageID: messageID,
					text: trimmed,
					clientEditID: clientEditID,
					expectedEditRevision: expectedRevision
				)
			} catch {
				guard batchForwardFailureIsUncertain(error) else { throw error }
				response = try await api.editMessage(
					context: context,
					messageID: messageID,
					text: trimmed,
					clientEditID: clientEditID,
					expectedEditRevision: expectedRevision
				)
			}
			guard isCurrentRemoteScope(scope),
                  activeRealtimeConversationID == conversationID,
                  let currentConversation = conversationStore.conversationMessageSnapshot(id: conversationID),
                  let currentMessage = currentConversation.messages.first(where: { $0.id == messageID }) else { return false }
			let authoritativeMessage: RemoteMessage?
            if let remote = response.message {
                guard remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines) == messageID,
                      remote.editRevision > expectedRevision,
                      messageEditResponseBelongsToConversation(
                        channelID: remote.channelID,
                        channelType: remote.channelType,
                        conversation: currentConversation
                      ),
                      messageEditResponseText(remote.payload) == trimmed else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("服务端返回的编辑正文或会话不一致，请刷新后重试")
                    return false
                }
                authoritativeMessage = remote
            } else {
                authoritativeMessage = nil
            }
			let authoritativeExtra: RemoteMessageExtra?
            if let extra = response.extra {
                guard extra.messageID.trimmingCharacters(in: .whitespacesAndNewlines) == messageID,
                      extra.normalizedExtraType == "edit",
                      extra.editRevision > expectedRevision,
                      messageEditResponseBelongsToConversation(
                        channelID: extra.channelID,
                        channelType: extra.channelType,
                        conversation: currentConversation
                      ),
                      messageEditResponseText(extra.payload) == trimmed else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("服务端返回的编辑正文或会话不一致，请刷新后重试")
                    return false
                }
                authoritativeExtra = extra
            } else {
                authoritativeExtra = nil
            }
			let authorityRevision = max(authoritativeMessage?.editRevision ?? 0, authoritativeExtra?.editRevision ?? 0)
			guard authorityRevision > expectedRevision else {
				/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("服务端未返回可验证的编辑版本，请刷新后重试")
				return false
			}
			if currentMessage.editRevision >= authorityRevision,
               currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息已被更新，请刷新最新内容后重试")
                return false
            }
			if let authoritativeMessage,
               authoritativeMessage.editRevision > currentMessage.editRevision {
				applyRemoteMessages([authoritativeMessage], channelID: authoritativeMessage.channelID, channelType: authoritativeMessage.channelType)
			}
			if let authoritativeExtra,
               authoritativeExtra.editRevision > (conversationStore.conversationMessageSnapshots()
                .first(where: { $0.id == conversationID })?
                .messages.first(where: { $0.id == messageID })?
                .editRevision ?? 0) {
				applyRemoteMessageExtra(authoritativeExtra, fromRealtime: false)
			}
			guard isCurrentRemoteScope(scope),
                  activeRealtimeConversationID == conversationID,
                  let projectedMessage = conversationStore.conversationMessageSnapshots()
                    .first(where: { $0.id == conversationID })?
                    .messages.first(where: { $0.id == messageID }),
                  projectedMessage.editRevision >= authorityRevision,
                  projectedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("服务端编辑结果尚未收敛，请刷新后重试")
                return false
            }
			/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(shouldShowMessageProcessingNotices ? "消息编辑已同步" : nil)
			return true
		} catch {
			guard isCurrentRemoteScope(scope), activeRealtimeConversationID == conversationID else { return false }
			/* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(messageEditFailureMessage(error))
			return false
		}
    }

	func messageEditUnavailableReason(_ message: ChatMessage, policy: MessageActionsPolicy? = nil) -> String? { // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        if let reason = messageActionPolicyUnavailableReason(.edit, policy: policy) { return reason } // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
		guard message.isOutgoing, isCurrentMessageSender(message.senderId) else { return "只能编辑自己发送的消息" }
		let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !messageID.isEmpty, !messageID.hasPrefix("local_") else { return "消息尚未完成服务端同步" }
		guard message.kind == .text else { return "仅支持编辑普通文本消息" }
		let contentType = message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard contentType.isEmpty || ["text", "plain_text", "text/plain"].contains(contentType) else { return "仅支持编辑普通文本消息" }
		guard message.status != .sending, message.status != .failed else { return "消息尚未发送成功" }
		guard message.status != .recalled, !message.isDeletedLocally else { return "消息已撤回或删除" }
		guard message.attachmentFileID == nil, !message.isStickerMessage, !message.isRTCCallRecordMessage else { return "该消息类型不支持编辑" }
		return nil
	}

	private func messageEditFailureMessage(_ error: Error) -> String {
        if case let IMAPIError.businessForbidden(code, _, _) = error,
           ["message_edit_disabled_by_policy", "message_actions_policy_unavailable"].contains(code) {
            refreshAppInteractionPolicy(force: true)
        }
		if let apiError = error as? IMAPIError {
			let code: String
			let message: String
			switch apiError {
			case .businessForbidden(let value, let raw, _), .conflict(let value, let raw):
				code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				message = raw
			case .httpStatus(let status, let raw):
				code = "http_\(status)"
				message = raw
			case .forbidden(let raw), .server(let raw):
				code = raw.lowercased()
				message = raw
			default:
				return "消息编辑失败：\(userFacingError(error))"
			}
			switch code {
			case "message_edit_disabled_by_policy": return "当前企业已关闭消息编辑"
			case "message_actions_policy_unavailable", "http_503": return "企业消息编辑策略暂时无法读取，请稍后重试"
			case "message_edit_revision_conflict": return "消息已在其他端更新，请刷新最新内容后重试"
			case "idempotency_conflict": return "本次编辑请求与已提交内容冲突，请重新编辑"
			case "message_edit_unsupported": return "仅支持编辑普通文本消息"
			case "invalid_message_state": return "消息已撤回、删除或状态已变化，无法编辑"
			case "forbidden": return "只能编辑自己发送的消息"
			case "not_found": return "消息不存在或已不在当前会话"
			case "empty_message": return "编辑内容不能为空"
			default:
				if message.contains("消息操作策略") { return "企业消息编辑策略暂时无法读取，请稍后重试" }
				return "消息编辑失败：\(message)"
			}
		}
		if error is URLError { return "网络暂时不可用，消息未改动，请重试" }
		return "消息编辑失败：\(userFacingError(error))"
	}

    func recallMessage(messageID: String, in conversationID: String) {
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversationStore.conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex]
        if let reason = messageRecallUnavailableReason(message) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let generation = localMessageSessionGeneration
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在撤回消息")
        Task {
            do {
                try await api.recallMessage(context: context, messageID: messageID)
                guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
                guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }),
                      let mIndex = conversationStore.conversationMessageSnapshot(at: cIndex).messages.firstIndex(where: { $0.id == messageID }) else { return }
                let senderName = conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex].isOutgoing ? "你" : conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex].senderName
                invalidateIndexedMediaCache(
                    for: conversationStore.conversationMessageSnapshot(at: cIndex).messages[mIndex],
                    state: .recalled
                )
                conversationStore.applyRecall(
                    messageID: messageID,
                    conversationID: conversationID,
                    recallText: "\(senderName)撤回了一条消息"
                )
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(shouldShowMessageProcessingNotices ? "消息已撤回" : nil)
                await persistConversationSnapshotImmediately(
                    conversationID: conversationID, scope: scope, source: .localMutation
                )
            } catch {
                guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
                handleRemoteError(error, fallback: "消息撤回失败")
            }
        }
    }

    func deleteOwnMessage(messageID: String, in conversationID: String, as deletion: OwnMessageDeletion) async {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              !isSystemReadOnlyConversation(conversation),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              OwnMessageDeletion.available(for: message, isCurrentSender: isCurrentMessageSender(message.senderId)) == deletion else { return }

        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let generation = localMessageSessionGeneration
        let operationKey = "\(generation):\(messageID)"
        guard pendingMessageDeletions.insert(operationKey).inserted else { return }
        defer { pendingMessageDeletions.remove(operationKey) }

        do {
            switch deletion {
            case .sent:
                let response = try await api.deleteMessage(context: context, messageID: messageID)
                guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
                let version = response.extra.flatMap { extra -> String? in
                    guard extra.tenantID == context.tenantID, extra.messageID == messageID,
                          extra.normalizedExtraType == "delete" else { return nil }
                    return String(max(0, extra.version))
                }
                applyAdminDeletedMessage(messageID: messageID, conversationID: conversationID, authorityVersion: version)
            case .failed:
                let ticket: LocalMessageSessionTicket
                if let localMessageTicket {
                    ticket = localMessageTicket
                } else {
                    ticket = try await messagePersistence.ensureTicket(context: context, sessionGeneration: generation)
                }
                guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
                let didDiscard = try await messagePersistence.discardFailedOutgoing(
                    ticket: ticket,
                    clientMessageID: messageID,
                    conversationID: conversationID,
                    channelID: remoteChannelID(for: conversation),
                    channelType: apiChannelType(for: conversation.kind)
                )
                guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
                guard didDiscard else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("消息正在同步，请稍后重试")
                    return
                }
                fileStore.cancelAttachmentUpload(messageID: messageID)
                invalidateIndexedMediaCache(for: message, state: .deleted)
                conversationStore.removeMessage(messageID: messageID, conversationID: conversationID)
            }
            await persistConversationSnapshotImmediately(conversationID: conversationID, scope: scope, source: .localMutation)
            guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(deletion == .failed ? "已删除失败消息" : (shouldShowMessageProcessingNotices ? "消息已删除" : nil))
        } catch {
            guard isCurrentRemoteScope(scope), localMessageSessionGeneration == generation else { return }
            handleRemoteError(error, fallback: "删除消息失败")
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

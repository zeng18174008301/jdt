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

// MARK: - Message Actions

extension AppState {
    func deleteConversation(_ conversationID: String) {
        guard let targetConversation = conversations.first(where: { $0.id == conversationID }),
              conversationListSupportsMutableActions(targetConversation) else { return }
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
        toast = "已删除会话 \(removed.title)"
    }

    func resend(messageID: String, in conversationID: String) {
        guard let ticket = localMessageTicket else {
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
                    resendClaimed(messageID: messageID, in: conversationID, durableTicket: nil)
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
                    toast = "消息当前不可重发"
                    return
                }
                resendClaimed(messageID: messageID, in: conversationID, durableTicket: ticket)
            } catch {
                markMessageFailed(messageID: messageID, in: conversationID)
                toast = "消息重发准备失败，请稍后重试"
            }
        }
    }

    func resendClaimed(
        messageID: String,
        in conversationID: String,
        durableTicket claimedTicket: LocalMessageSessionTicket?
    ) {
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let originalMessage = conversations[cIndex].messages[mIndex]
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
                toast = "该联系人缺少用户ID，暂不能发送名片"
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
                toast = "附件缺少上传文件ID，请重新选择后发送"
                return
            }
            resolvedAttachmentFile = file
        } else {
            resolvedAttachmentFile = nil
        }
        if isSystemReadOnlyConversation(conversations[cIndex]) {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            toast = "系统通知仅支持阅读"
            return
        }
        if let message = directSendBlockedMessage(for: conversations[cIndex]) {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            toast = message
            return
        }
        if let message = localSendPolicyBlockedMessage(for: conversations[cIndex]) {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            toast = message
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
            toast = "登录会话不可用，请重新登录"
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
        toast = "正在重新发送"
        let conversation = conversations[cIndex]
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
                    let durationMS = message.attachmentDurationSeconds.map { Int(($0 * 1_000).rounded()) }
                        ?? VoiceMessagePayload.minDurationMS
                    remote = try await api.sendVoice(
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
                } else if message.kind == .file || message.kind == .image {
                    remote = try await api.sendAttachment(
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
                } else if message.kind == .contactCard {
                    remote = try await api.sendContactCard(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        contactID: resolvedContactID ?? message.attachmentMeta ?? "",
                        contactName: contactCardExportDisplayName(from: message),
                        contactAvatar: (resolvedContactID ?? message.attachmentMeta).flatMap { contactCardAvatarURL(for: $0) },
                        quote: message.quote,
                        clientMessageID: message.id
                    )
                } else if message.isStickerMessage {
                    guard let stickerSnapshot = message.stickerSnapshot else {
                        conversationStore.markMessageResendFailed(messageID: messageID, conversationID: conversationID)
                        toast = "表情资源缺少快照，暂不能重发"
                        return
                    }
                    remote = try await api.sendSticker(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        sticker: stickerSnapshot,
                        quote: message.quote,
                        replyContext: message.replyContext,
                        clientMessageID: message.id
                    )
                } else {
                    remote = try await api.sendText(context: context, conversation: conversation, channelID: channelID, text: message.text, quote: message.quote, replyContext: message.replyContext, clientMessageID: message.id, mentionAll: message.mentionAll, mentionedUsers: message.mentionedUsers)
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
        let conversation = conversations.first { conversation in
            conversation.messages.contains(where: { $0.id == message.id })
        }
        iosRiskTelemetry.recordClipboardCopy(
            characterCount: message.text.count,
            resourceType: "message",
            resourceID: message.id,
            channelType: conversation.map { apiChannelType(for: $0.kind) },
            channelID: conversation.map { remoteChannelID(for: $0) }
        )
        toast = "已复制消息内容"
    }

    func loadReadReceipts(messageID: String, in conversationID: String) {
        Task {
            guard let initialConversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
                  let initialMessageIndex = conversations[initialConversationIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
            guard conversations[initialConversationIndex].messages[initialMessageIndex].isOutgoing else {
                toast = "只能查看自己发送消息的已读状态"
                return
            }
            guard fileUploadConfig.readReceiptsEnabled else {
                return
            }
            let context = apiContext
            guard context.hasIMSession else {
                toast = "登录会话不可用，请重新登录"
                return
            }
            let scope = remoteDataScopeKey(for: context)
            let response: RemoteMessageReadReceiptResponse
            let generation = localMessageSessionGeneration
            do {
                response = try await api.messageReadReceipts(context: context, messageID: messageID)
            } catch {
                guard isCurrentRemoteScope(scope), generation == localMessageSessionGeneration,
                      context.sessionEpoch == apiContext.sessionEpoch else { return }
                logSyncEndpointFailure("/api/im/messages/{message_id}/read-receipts", error: error)
                if shouldShowGroupHistoryLimitedMessage(for: error, conversationID: conversationID) {
                    toast = groupHistoryLimitedMessage
                    return
                }
                if isCapabilityError(error, code: "read_receipts_not_enabled") {
                    setReadReceiptsEnabled(false)
                    return
                }
                handleRemoteError(error, fallback: "已读状态获取失败")
                return
            }
            guard isCurrentRemoteScope(scope), generation == localMessageSessionGeneration,
                  context.sessionEpoch == apiContext.sessionEpoch else { return }
            if response.readReceiptsEnabled == false || response.featureStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "disabled" {
                setReadReceiptsEnabled(false)
                return
            }
            let didChange = conversationStore.applyRemoteReadReceiptDetails(
                response: response,
                messageID: messageID,
                conversationID: conversationID,
                makeReadReceipt: { receipt, conversation in
                    ReadReceipt(
                        id: "\(receipt.imUID)_\(receipt.deviceID)_\(receipt.channelSeq)",
                        user: readReceiptUser(
                            imUID: receipt.imUID,
                            conversation: conversation,
                            nickname: receipt.nickname,
                            displayName: receipt.displayName,
                            remark: receipt.remark
                        ),
                        device: receipt.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "设备未同步" : receipt.deviceID,
                        time: displayTime(receipt.createdAt)
                    )
                },
                makeUnreadReceipt: { participant, conversation in
                    ReadReceipt(
                        id: "unread_\(participant.imUID)",
                        user: readReceiptUser(
                            imUID: participant.imUID,
                            conversation: conversation,
                            nickname: participant.nickname,
                            displayName: participant.displayName,
                            remark: participant.remark
                        ),
                        device: participant.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未同步" : participant.deviceID,
                        time: participant.readAt.map(displayTime) ?? "未读"
                    )
                },
                makeReactionDetail: reactionDetail(from:)
            )
            if didChange, conversations.first(where: { $0.id == conversationID })?.kind == .group,
               !shouldShowGroupMemberCount {
                conversationStore.scrubGroupMemberTotals()
            }
            if didChange {
                await persistConversationSnapshotImmediately(
                    conversationID: conversationID, scope: scope, source: .localMutation
                )
            }
        }
    }

    func readReceiptUser(imUID: String, conversation: Conversation, nickname: String? = nil, displayName: String? = nil, remark: String? = nil) -> IMUser {
        let normalizedID = imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupMember = groups.lazy.flatMap(\.members).first { $0.id == normalizedID || $0.userID == normalizedID }
        let participant = conversation.participants.first { $0.id == normalizedID || $0.userID == normalizedID }
        let contact = contacts.first { $0.id == normalizedID || $0.userID == normalizedID }
        let fallback = groupMember ?? participant ?? contact
        let name = remarkPreferredDisplayName(
            identifiers: [normalizedID, fallback?.id ?? "", fallback?.userID ?? "", fallback?.username ?? ""],
            candidates: [remark, displayName, nickname, groupMember?.name, participant?.name, contact?.name, contact?.username, contact?.userID],
            fallback: normalizedID
        )
        return IMUser(
            id: fallback?.id ?? normalizedID,
            name: name,
            title: fallback?.title ?? "",
            department: fallback?.department ?? "",
            departmentPathNames: fallback?.departmentPathNames ?? [],
            phone: fallback?.phone ?? "",
            email: fallback?.email ?? "",
            status: fallback?.status ?? "在线",
            enterprise: fallback?.enterprise ?? currentEnterprise.name,
            avatarSeed: fallback?.avatarSeed ?? stableSeed(normalizedID),
            avatarURL: fallback?.avatarURL ?? "",
            badges: fallback?.badges ?? []
        )
    }

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
        conversation: Conversation
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
			toast = "编辑内容不能为空"
			return false
		}
		guard let conversation = conversations.first(where: { $0.id == conversationID }),
		      let message = conversation.messages.first(where: { $0.id == messageID }) else {
			toast = "消息不存在或已不在当前会话"
			return false
		}
		if let reason = messageEditUnavailableReason(message) {
			toast = reason
			return false
		}
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
			return false
        }
		let clientEditID = UUID().uuidString.lowercased()
		let expectedRevision = max(0, message.editRevision)
		toast = "正在保存编辑"
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
                  let currentConversation = conversations.first(where: { $0.id == conversationID }),
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
                    toast = "服务端返回的编辑正文或会话不一致，请刷新后重试"
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
                    toast = "服务端返回的编辑正文或会话不一致，请刷新后重试"
                    return false
                }
                authoritativeExtra = extra
            } else {
                authoritativeExtra = nil
            }
			let authorityRevision = max(authoritativeMessage?.editRevision ?? 0, authoritativeExtra?.editRevision ?? 0)
			guard authorityRevision > expectedRevision else {
				toast = "服务端未返回可验证的编辑版本，请刷新后重试"
				return false
			}
			if currentMessage.editRevision >= authorityRevision,
               currentMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed {
                toast = "消息已被更新，请刷新最新内容后重试"
                return false
            }
			if let authoritativeMessage,
               authoritativeMessage.editRevision > currentMessage.editRevision {
				applyRemoteMessages([authoritativeMessage], channelID: authoritativeMessage.channelID, channelType: authoritativeMessage.channelType)
			}
			if let authoritativeExtra,
               authoritativeExtra.editRevision > (conversations
                .first(where: { $0.id == conversationID })?
                .messages.first(where: { $0.id == messageID })?
                .editRevision ?? 0) {
				applyRemoteMessageExtra(authoritativeExtra, fromRealtime: false)
			}
			guard isCurrentRemoteScope(scope),
                  activeRealtimeConversationID == conversationID,
                  let projectedMessage = conversations
                    .first(where: { $0.id == conversationID })?
                    .messages.first(where: { $0.id == messageID }),
                  projectedMessage.editRevision >= authorityRevision,
                  projectedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                toast = "服务端编辑结果尚未收敛，请刷新后重试"
                return false
            }
			toast = "消息编辑已同步"
			return true
		} catch {
			guard isCurrentRemoteScope(scope), activeRealtimeConversationID == conversationID else { return false }
			toast = messageEditFailureMessage(error)
			return false
		}
    }

	func messageEditUnavailableReason(_ message: ChatMessage) -> String? {
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
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = conversations[cIndex].messages[mIndex]
        if let reason = messageRecallUnavailableReason(message) {
            toast = reason
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        toast = "正在撤回消息"
        Task {
            do {
                try await api.recallMessage(context: context, messageID: messageID)
                guard isCurrentRemoteScope(scope) else { return }
                guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
                      let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
                let senderName = conversations[cIndex].messages[mIndex].isOutgoing ? "你" : conversations[cIndex].messages[mIndex].senderName
                invalidateIndexedMediaCache(
                    for: conversations[cIndex].messages[mIndex],
                    state: .recalled
                )
                conversationStore.applyRecall(
                    messageID: messageID,
                    conversationID: conversationID,
                    recallText: "\(senderName)撤回了一条消息"
                )
                toast = "消息已撤回"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "消息撤回失败")
            }
        }
    }

    func canAdminDeleteMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
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
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let conversation = conversations[cIndex]
        let message = conversations[cIndex].messages[mIndex]
        guard canAdminDeleteMessage(message, in: conversationID) else {
            toast = "仅群主或管理员可以对全员删除消息"
            return
        }
        let groupID = remoteChannelID(for: conversation)
        guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            toast = "群聊不存在或已删除"
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let channelType = apiChannelType(for: conversation.kind)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        guard fileUploadConfig.groupAdminDeleteMessageEnabled else {
            toast = "当前企业未开通"
            return
        }
        toast = "正在删除消息"
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
                toast = "已对全员删除该消息"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if let message = adminDeleteFailureMessage(error) {
                    toast = message
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

    private func groupForConversation(_ conversation: Conversation) -> GroupInfo? {
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
        let cachedMessage = conversations.lazy.compactMap { conversation in
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

    func messageRecallUnavailableReason(_ message: ChatMessage) -> String? {
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
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let currentValue = conversationStore.messagePinnedState(messageID: messageID, conversationID: conversationID) else { return }
        let nextValue = !currentValue
        let conversation = conversations[cIndex]
        let channelID = remoteChannelID(for: conversation)
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
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
                toast = nextValue ? "已置顶单条消息" : "已取消消息置顶"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                    toast = groupHistoryLimitedMessage
                    return
                }
                handleRemoteError(error, fallback: nextValue ? "置顶消息失败" : "取消置顶失败")
            }
        }
    }

    func refreshPinnedMessages(for conversationID: String, silent: Bool = true) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[index].kind == .group else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else { return }
        let channelID = remoteChannelID(for: conversations[index])
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
                guard let conversation = conversationStore.conversation(id: conversationID) else { return }
                let entries = pinnedMessageSnapshotEntries(from: remotes, participants: conversation.participants)
                conversationStore.applyPinnedMessageSnapshot(entries, conversationID: conversationID)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if silent {
                    logSyncEndpointFailure("/api/im/groups/\(channelID)/pinned-messages", error: error)
                } else {
                    if let conversation = conversations.first(where: { $0.id == conversationID }),
                       shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                        toast = groupHistoryLimitedMessage
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
              let conversation = conversations.first(where: { $0.id == conversationID }),
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
            toast = "该消息暂不能举报"
            return .failed
        }
        guard MessageReportCategory.allowedReasons.contains(normalizedReason) else {
            toast = "请选择举报分类"
            return .failed
        }
        guard !normalizedDescription.isEmpty else {
            toast = "请输入举报理由"
            return .failed
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return .failed
        }
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let targetMessage = conversation.messages.first(where: { $0.id == normalizedMessageID }) else {
            toast = "消息不存在或已刷新"
            return .failed
        }
        guard !isCurrentMessageSender(targetMessage.senderId) else {
            toast = "不能举报自己发送的消息"
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
                toast = "已举报成功"
                return .alreadyReported(report)
            }
            toast = "举报已提交"
            return .submitted(report)
        } catch {
            guard isCurrentRemoteScope(scope) else { return .failed }
            handleRemoteError(error, fallback: "提交举报失败")
            return .failed
        }
    }

    func batchForwardEligibility(
        for message: ChatMessage,
        in conversationID: String
    ) -> BatchForwardEligibility {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let snapshot = batchForwardSnapshot(message, in: conversation) else {
            return .disabled("消息不存在或尚未加载")
        }
        return BatchForwardSemantics.eligibility(
            of: snapshot,
            actorUID: batchForwardActorUID()
        )
    }

    func beginBatchForward(
        conversationID: String,
        initialMessageID: String
    ) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .direct || conversation.kind == .group else {
            toast = "当前会话不支持批量转发"
            return
        }
        guard let scope = batchForwardScope(for: conversation) else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        var next: BatchForwardState
        if let current = batchForwardState,
           current.scope == scope,
           batchForwardSourceConversationID == conversationID {
            next = current
        } else {
            next = BatchForwardState(scope: scope)
        }
        next.ingestSourcePage(
            conversation.messages.compactMap { batchForwardSnapshot($0, in: conversation) }
        )
        next.ingestTargets(batchForwardTargetCandidates().map(\.target))
        switch next.toggleSource(initialMessageID) {
        case .selected, .removed:
            batchForwardSourceConversationID = conversationID
            batchForwardState = next
        case .rejected(let reason):
            toast = reason
        }
    }

    func refreshBatchForwardContext(conversationID: String) {
        if let sourceConversationID = batchForwardSourceConversationID,
           sourceConversationID != conversationID {
            resetBatchForwardDraftForScopeChange()
            return
        }
        guard batchForwardSourceConversationID == conversationID,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              var next = batchForwardState else {
            return
        }
        next.ingestSourcePage(
            conversation.messages.compactMap { batchForwardSnapshot($0, in: conversation) }
        )
        next.ingestTargets(batchForwardTargetCandidates().map(\.target))
        batchForwardState = next
    }

    func leaveBatchForwardSourceConversation(_ conversationID: String) {
        guard batchForwardSourceConversationID == conversationID else {
            return
        }
        resetBatchForwardDraftForScopeChange()
    }

    func toggleBatchForwardSource(
        messageID: String,
        conversationID: String
    ) {
        guard batchForwardSourceConversationID == conversationID,
              var next = batchForwardState else {
            return
        }
        switch next.toggleSource(messageID) {
        case .selected, .removed:
            batchForwardState = next
        case .rejected(let reason):
            toast = reason
        }
    }

    func batchForwardTarget(for conversation: Conversation) -> BatchForwardTarget? {
        guard conversation.kind == .direct || conversation.kind == .group else {
            return nil
        }
        let channelID = remoteChannelID(for: conversation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else {
            return nil
        }
        let participantTerms = conversation.participants.flatMap {
            [$0.id, $0.userID, $0.username, $0.name]
        }
        return BatchForwardTarget(
            channelID: channelID,
            channelType: apiChannelType(for: conversation.kind),
            displayName: conversation.title,
            searchTerms: [
                conversation.subtitle,
                conversation.lastMessage
            ] + participantTerms
        )
    }

    func batchForwardTargetCandidates() -> [BatchForwardTargetCandidate] {
        var ordered: [BatchForwardTargetCandidate] = []
        var indexByIdentity: [String: Int] = [:]

        func append(_ candidate: BatchForwardTargetCandidate?) {
            guard let candidate else { return }
            if let index = indexByIdentity[candidate.identityKey] {
                ordered[index] = candidate
            } else {
                indexByIdentity[candidate.identityKey] = ordered.count
                ordered.append(candidate)
            }
        }

        // Preserve conversation order for recent/frequent ranking, then enrich
        // and complete the same canonical identities from the full friend/group
        // stores. The source conversation remains a valid target.
        conversations.forEach { append(batchForwardTargetCandidate(for: $0)) }
        contacts.forEach { append(batchForwardTargetCandidate(for: $0)) }
        groups.forEach { append(batchForwardTargetCandidate(for: $0)) }
        return ordered
    }

    func forwardTenantFile(_ file: FileItem, to target: BatchForwardTarget) async -> Bool {
        let fileID = file.remoteLookupID
        let actorUID = batchForwardActorUID()
        let channelID = target.canonicalChannelID(actorUID: actorUID)
        let channelType = BatchForwardSemantics.canonicalChannelType(target.channelType)
        guard !fileID.isEmpty, !channelID.isEmpty, ["direct", "group"].contains(channelType) else {
            toast = "文件或目标会话不可用，请刷新后重试"
            return false
        }
        guard !forwardingTenantFileIDs.contains(fileID) else { return false }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录状态失效，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let idempotencyScope = "\(scope)|\(fileID)|\(channelType)|\(channelID)"
        let clientMessageID = tenantFileForwardClientMessageIDs[idempotencyScope]
            ?? "ios_file_forward_\(UUID().uuidString.lowercased())"
        tenantFileForwardClientMessageIDs[idempotencyScope] = clientMessageID
        forwardingTenantFileIDs.insert(fileID)
        defer { forwardingTenantFileIDs.remove(fileID) }
        do {
            let message = try await api.forwardTenantFile(
                context: context,
                fileID: fileID,
                targetChannelID: channelID,
                targetChannelType: channelType,
                clientMessageID: clientMessageID
            )
            guard isCurrentRemoteScope(scope) else { return false }
            applyRemoteMessages(
                [message],
                channelID: message.channelID.isEmpty ? channelID : message.channelID,
                channelType: message.channelType.isEmpty ? channelType : message.channelType
            )
            tenantFileForwardClientMessageIDs.removeValue(forKey: idempotencyScope)
            toast = "文件已转发至 \(target.displayName)"
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "文件转发失败，请重试")
            return false
        }
    }

    func batchForwardVisibleTargetCandidates(
        from candidates: [BatchForwardTargetCandidate],
        initialLimit: Int = 20
    ) -> [BatchForwardTargetCandidate] {
        guard let batchForwardState else {
            return []
        }
        let visibleKeys = Set(
            batchForwardState
                .visibleTargets(
                    candidates: candidates.map(\.target),
                    initialLimit: initialLimit
                )
                .map { $0.identityKey(actorUID: batchForwardState.scope.actorUID) }
        )
        return candidates.filter { candidate in
            visibleKeys.contains(candidate.identityKey)
        }
    }

    func isBatchForwardTargetSelected(_ conversation: Conversation) -> Bool {
        guard let target = batchForwardTarget(for: conversation) else {
            return false
        }
        return isBatchForwardTargetSelected(target)
    }

    func isBatchForwardTargetSelected(_ target: BatchForwardTarget) -> Bool {
        guard let batchForwardState else { return false }
        return batchForwardState.selectedTargetIdentityKeysInOrder.contains(
            target.identityKey(actorUID: batchForwardState.scope.actorUID)
        )
    }

    func toggleBatchForwardTarget(_ conversation: Conversation) {
        guard let target = batchForwardTarget(for: conversation) else {
            toast = "目标会话不可用，请刷新后重试"
            return
        }
        toggleBatchForwardTarget(target)
    }

    func toggleBatchForwardTarget(_ target: BatchForwardTarget) {
        guard var next = batchForwardState else { return }
        next.ingestTargets([target])
        let identityKey = target.identityKey(actorUID: next.scope.actorUID)
        switch next.toggleTarget(identityKey) {
        case .selected, .removed:
            batchForwardState = next
        case .rejected(let reason):
            toast = reason
        }
    }

    private func batchForwardTargetCandidate(
        for conversation: Conversation
    ) -> BatchForwardTargetCandidate? {
        guard let target = batchForwardTarget(for: conversation) else {
            return nil
        }
        let peer = conversation.kind == .direct
            ? conversation.participants.first(where: {
                !isCurrentUserIdentity($0.id)
                    && !isCurrentUserIdentity($0.userID)
                    && !isCurrentUserIdentity($0.username)
            }) ?? conversation.participants.first
            : nil
        let subtitle: String
        if conversation.kind == .group {
            let count = visibleGroupMemberCount(
                conversation.memberCount,
                conversation.participants.count
            )
            subtitle = count.map { "\($0) 人 · 群聊" } ?? "群聊"
        } else {
            let status = peer?.status.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            subtitle = status.isEmpty ? "好友" : status
        }
        return canonicalBatchForwardTargetCandidate(
            target: target,
            subtitle: subtitle,
            avatarSeed: peer?.avatarSeed ?? conversation.accentHex,
            avatarURL: peer?.displayAvatarURL ?? conversation.avatarURL,
            avatarVersion: peer?.avatarVersion ?? conversation.avatarVersion,
            avatarUpdatedAt: peer?.avatarUpdatedAt ?? conversation.avatarUpdatedAt,
            memberCount: conversation.kind == .group ? conversation.memberCount : nil
        )
    }

    private func batchForwardTargetCandidate(
        for contact: IMUser
    ) -> BatchForwardTargetCandidate? {
        guard !contact.isCancelledUser else { return nil }
        let identities = userIdentityCandidates(for: contact)
        guard !identities.isEmpty,
              identities.allSatisfy({ !isCurrentUserIdentity($0) }),
              let peerID = identities.first else {
            return nil
        }
        let displayName = remarkPreferredDisplayName(
            for: contact,
            fallback: peerID
        )
        let target = BatchForwardTarget(
            channelID: peerID,
            channelType: "direct",
            displayName: displayName,
            searchTerms: identities + [
                contact.name,
                contact.title,
                contact.department,
                contact.status
            ]
        )
        let status = contact.status.trimmingCharacters(in: .whitespacesAndNewlines)
        let department = contact.department.trimmingCharacters(in: .whitespacesAndNewlines)
        return canonicalBatchForwardTargetCandidate(
            target: target,
            subtitle: !status.isEmpty ? status : (!department.isEmpty ? department : "好友"),
            avatarSeed: contact.avatarSeed == 0 ? stableSeed(peerID) : contact.avatarSeed,
            avatarURL: contact.displayAvatarURL,
            avatarVersion: contact.avatarVersion,
            avatarUpdatedAt: contact.avatarUpdatedAt,
            memberCount: nil
        )
    }

    private func batchForwardTargetCandidate(
        for group: GroupInfo
    ) -> BatchForwardTargetCandidate? {
        let groupID = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupID.isEmpty else { return nil }
        let displayName = group.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = BatchForwardTarget(
            channelID: groupID,
            channelType: "group",
            displayName: displayName.isEmpty ? groupID : displayName,
            searchTerms: [
                group.notice,
                group.owner,
                group.ownerID
            ] + group.members.flatMap {
                [$0.id, $0.userID, $0.username, $0.name]
            }
        )
        let count = group.visibleMemberCount
        return canonicalBatchForwardTargetCandidate(
            target: target,
            subtitle: count.map { "\($0) 人 · 群聊" } ?? "群聊",
            avatarSeed: stableSeed(groupID),
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt,
            memberCount: count
        )
    }

    private func canonicalBatchForwardTargetCandidate(
        target: BatchForwardTarget,
        subtitle: String,
        avatarSeed: UInt,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String,
        memberCount: Int?
    ) -> BatchForwardTargetCandidate? {
        let actorUID = batchForwardState?.scope.actorUID ?? batchForwardActorUID()
        guard !actorUID.isEmpty else { return nil }
        let canonical = BatchForwardTarget(
            channelID: target.canonicalChannelID(actorUID: actorUID),
            channelType: BatchForwardSemantics.canonicalChannelType(target.channelType),
            displayName: target.displayName,
            searchTerms: target.searchTerms
        )
        let identityKey = canonical.identityKey(actorUID: actorUID)
        guard canonical.tab != nil,
              !canonical.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return BatchForwardTargetCandidate(
            identityKey: identityKey,
            target: canonical,
            subtitle: subtitle,
            avatarSeed: avatarSeed,
            avatarURL: avatarURL,
            avatarVersion: avatarVersion,
            avatarUpdatedAt: avatarUpdatedAt,
            memberCount: memberCount
        )
    }

    func removeBatchForwardTarget(identityKey: String) {
        guard var next = batchForwardState,
              next.selectedTargetIdentityKeysInOrder.contains(identityKey) else {
            return
        }
        _ = next.toggleTarget(identityKey)
        batchForwardState = next
    }

    func setBatchForwardTargetTab(_ tab: BatchForwardTargetTab) {
        guard var next = batchForwardState else { return }
        next.setActiveTargetTab(tab)
        batchForwardState = next
    }

    func setBatchForwardTargetSearchQuery(_ query: String) {
        guard var next = batchForwardState else { return }
        next.setTargetSearchQuery(query)
        batchForwardState = next
    }

    func setBatchForwardTargetTabExpanded(
        _ tab: BatchForwardTargetTab,
        expanded: Bool
    ) {
        guard var next = batchForwardState else { return }
        next.setTargetTabExpanded(tab, expanded: expanded)
        batchForwardState = next
    }

    func cancelBatchForward() {
        guard var next = batchForwardState else { return }
        if case .submitting = next.submissionPhase {
            toast = "批量转发正在提交"
            return
        }
        next.cancel()
        invalidateBatchForwardSubmission()
        batchForwardState = nil
        batchForwardSourceConversationID = nil
    }

    func submitBatchForward() {
        guard var next = batchForwardState else { return }
        let begin = next.beginSubmission { UUID().uuidString }
        batchForwardState = next
        guard case .ready(let command) = begin else {
            if case .invalid(let reason) = begin {
                toast = reason
            }
            return
        }
        let context = apiContext
        let remoteScope = remoteDataScopeKey(for: context)
        let sourceConversationID = batchForwardSourceConversationID
        let submissionScope = next.scope
        let submittedTargets = next.selectedTargets
        invalidateBatchForwardSubmission()
        let submissionGeneration = batchForwardSubmissionGeneration
        batchForwardSubmissionTask = Task { @MainActor [weak self] in
            guard let self, let sourceConversationID else { return }
            defer {
                if self.batchForwardSubmissionGeneration == submissionGeneration {
                    self.batchForwardSubmissionTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await self.api.forwardBatch(
                    context: context,
                    command: command
                )
                try Task.checkCancellation()
                guard self.isCurrentBatchForwardSubmission(
                    generation: submissionGeneration,
                    remoteScope: remoteScope,
                    sourceConversationID: sourceConversationID,
                    submissionScope: submissionScope
                ),
                      var current = self.batchForwardState,
                      current.clientBatchID == command.request.clientBatchID else {
                    return
                }
                switch current.applyCommittedResult(result) {
                case .applied:
                    self.batchForwardState = current
                    _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                    try Task.checkCancellation()
                    guard self.isCurrentBatchForwardSubmission(
                        generation: submissionGeneration,
                        remoteScope: remoteScope,
                        sourceConversationID: sourceConversationID,
                        submissionScope: submissionScope
                    ) else {
                        return
                    }
                    for target in submittedTargets {
                        guard let targetConversationID = self.batchForwardConversation(
                            matching: target
                        )?.id else {
                            continue
                        }
                        self.syncConversationMessagesIfNeeded(
                            targetConversationID,
                            force: true,
                            silent: true,
                            showLoadingIndicator: false
                        )
                    }
                    self.toast = "已转发 \(result.sourceCount) 条消息到 \(result.targetCount) 个会话"
                case .rejected(let reason):
                    self.batchForwardState = current
                    self.toast = "服务端结果待确认：\(reason)"
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentBatchForwardSubmission(
                    generation: submissionGeneration,
                    remoteScope: remoteScope,
                    sourceConversationID: sourceConversationID,
                    submissionScope: submissionScope
                ),
                      var current = self.batchForwardState,
                      current.clientBatchID == command.request.clientBatchID else {
                    return
                }
                let message = self.userFacingError(error)
                if self.batchForwardFailureIsUncertain(error) {
                    current.markUncertain(message)
                } else {
                    current.markRetryableFailure(message)
                }
                self.batchForwardState = current
                self.handleRemoteError(error, fallback: "批量转发失败")
            }
        }
    }

    private func isCurrentBatchForwardSubmission(
        generation: UInt64,
        remoteScope: String,
        sourceConversationID: String,
        submissionScope: BatchForwardScope
    ) -> Bool {
        !Task.isCancelled
            && batchForwardSubmissionGeneration == generation
            && isCurrentRemoteScope(remoteScope)
            && batchForwardSourceConversationID == sourceConversationID
            && batchForwardState?.scope == submissionScope
    }

    private func batchForwardScope(for conversation: Conversation) -> BatchForwardScope? {
        let tenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actorUID = batchForwardActorUID()
        let channelID = remoteChannelID(for: conversation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenantID.isEmpty, !actorUID.isEmpty, !channelID.isEmpty else {
            return nil
        }
        return BatchForwardScope(
            tenantID: tenantID,
            actorUID: actorUID,
            sourceChannelID: channelID,
            sourceChannelType: apiChannelType(for: conversation.kind)
        )
    }

    private func batchForwardActorUID() -> String {
        apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func batchForwardSnapshot(
        _ message: ChatMessage,
        in conversation: Conversation
    ) -> BatchForwardMessageSnapshot? {
        let messageID = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = remoteChannelID(for: conversation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageID.isEmpty, !channelID.isEmpty else {
            return nil
        }
        let clientState: String
        if message.isDeletedLocally {
            clientState = "deleted"
        } else {
            switch message.status {
            case .sending: clientState = "sending"
            case .failed: clientState = "failed"
            case .recalled: clientState = "recalled"
            case .sent, .read: clientState = "sent"
            }
        }
        let nestedMarkers = [
            message.systemEventType,
            message.systemDisplayStyle,
            message.attachmentMeta,
            message.attachmentUploadStatus
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return BatchForwardMessageSnapshot(
            messageID: messageID,
            sourceChannelID: channelID,
            sourceChannelType: apiChannelType(for: conversation.kind),
            senderUID: message.senderId,
            senderProvenance: message.senderProvenance,
            channelSeq: message.channelSeq > 0 ? message.channelSeq : nil,
            createdAtMillis: message.createdAt.map {
                Int64($0.timeIntervalSince1970 * 1_000)
            },
            clientState: clientState,
            contentType: message.contentType,
            kind: message.kind.rawValue,
            mediaCategory: attachmentMediaCategory(for: message),
            previewKind: message.attachmentPreviewKind,
            nestedSemanticMarkers: nestedMarkers,
            fileName: message.attachmentName ?? "",
            mimeType: message.attachmentMimeType
        )
    }

    private func batchForwardConversation(
        matching target: BatchForwardTarget
    ) -> Conversation? {
        let actorUID = batchForwardState?.scope.actorUID ?? batchForwardActorUID()
        let identityKey = target.identityKey(actorUID: actorUID)
        return conversations.first {
            guard let candidate = batchForwardTarget(for: $0) else { return false }
            return candidate.identityKey(actorUID: actorUID) == identityKey
        }
    }

    private func batchForwardFailureIsUncertain(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        guard let apiError = error as? IMAPIError else {
            return true
        }
        switch apiError {
        case .httpStatus(let status, _):
            return status >= 500
        case .server, .emptyResponse:
            return true
        case .missingContext, .badURL, .unauthorized, .forbidden,
             .forcedAuthRequired, .businessForbidden, .conflict,
             .securityBlocked, .loginSecurity, .rateLimited:
            return false
        }
    }

    func forwardMessage(_ message: ChatMessage) {
        toast = message.isForwardSupported ? "请选择要转发到的会话" : "该消息类型暂不支持转发"
    }

    func forwardMessage(_ message: ChatMessage, to target: Conversation) {
        guard message.isForwardSupported else {
            toast = "该消息类型暂不支持转发"
            return
        }
        guard target.kind == .direct || target.kind == .group else {
            toast = "只能转发到单聊或群聊"
            return
        }
        let targetChannelID = remoteChannelID(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetChannelID.isEmpty else {
            toast = "目标会话不可用，请刷新后重试"
            return
        }
        let targetChannelType = apiChannelType(for: target.kind)
        let clientMessageID = "ios-forward-\(UUID().uuidString)"
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
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
                toast = "已转发到「\(target.title)」"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "消息转发失败")
            }
        }
    }

    func addReaction(_ emoji: String, to messageID: String, in conversationID: String) {
        guard let cIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let mIndex = conversations[cIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = conversations[cIndex].messages[mIndex]
        guard message.status != .failed, message.status != .sending else {
            toast = "消息发送成功后才能回应"
            return
        }
        let conversation = conversations[cIndex]
        if let message = localSendPolicyBlockedMessage(for: conversation) {
            toast = message
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
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
                toast = action == "remove" ? "已取消表情回应 \(emoji)" : "已添加表情回应 \(emoji)"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                applyMessageReaction(messageID: messageID, emoji: emoji, operatorUID: operatorUID, action: action == "remove" ? "add" : "remove")
                if shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation) {
                    toast = groupHistoryLimitedMessage
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
                toast = "表情回应失败，请稍后重试"
            }
        }
    }

}

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
    func shareContactCard(_ user: IMUser, to conversationID: String, quote: String? = nil) {
        guard let cIndex = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if isSystemReadOnlyConversation(conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("系统通知仅支持阅读")
            return
        }
        if let message = directSendBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        if let message = localSendPolicyBlockedMessage(for: conversationStore.conversationMessageSnapshot(at: cIndex)) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
            return
        }
        guard let contactID = contactCardUID(for: user) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该联系人缺少用户ID，暂不能发送名片")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        flushPendingRealtimeMessagesIfNeeded(reason: "before_send_contact_card")
        let localContactName = contactCardLocalDisplayName(for: user)
        let remoteContactName = contactCardExportDisplayName(for: user)
        let messageText = "个人名片：\(localContactName)"
        var message = ChatMessage(
            id: "local_\(UUID().uuidString)",
            senderId: localOutgoingMessageSenderID(),
            senderName: localOutgoingMessageSenderName(conversationID: conversationID),
            text: messageText,
            time: "刚刚",
            isOutgoing: true,
            status: .sending,
            kind: .contactCard,
            reactions: [],
            readBy: [],
            unreadBy: conversationStore.conversationMessageSnapshot(at: cIndex).participants.prefix(3).map { ReadReceipt(id: "card_pending_\($0.id)", user: $0, device: "未同步", time: "未读") },
            quote: quote,
            attachmentName: localContactName,
            attachmentMeta: contactID
        )
        message.createdAt = Date()
        guard let conversation = conversationStore.appendLocalOutgoingMessage(
            message,
            to: conversationID,
            preview: messageText
        ) else { return }
        let channelID = remoteChannelID(for: conversation)
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("名片发送中…")
        Task {
            var durableTicket: LocalMessageSessionTicket?
            do {
                durableTicket = try await enqueueDurableOutgoing(
                    messageID: message.id,
                    conversationID: conversationID,
                    operationKind: "send_contact_card",
                    context: context,
                    scope: scope
                )
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                let remote = try await withDurableOutgoingSend(ticket: durableTicket, messageID: message.id) {
                    try await api.sendContactCard(
                        context: context,
                        conversation: conversation,
                        channelID: channelID,
                        contactID: contactID,
                        contactName: remoteContactName,
                        contactAvatar: user.avatarURL,
                        quote: quote,
                        clientMessageID: message.id
                    )
                }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                guard isCurrentRemoteScope(scope) else { return }
                replaceMessageID(localID: message.id, remote: remote, in: conversationID)
                if let durableTicket {
                    await confirmDurableOutgoing(
                        ticket: durableTicket,
                        clientMessageID: message.id,
                        remote: remote,
                        conversationID: conversationID,
                        scope: scope
                    )
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("名片已发送")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
                if await retainUnconfirmedOutgoing(error, ticket: durableTicket, messageID: message.id,
                                                   conversationID: conversationID, scope: scope) { return }
                // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
                if isNotFriendsError(error) {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .failedPermanent)
                    removeMessage(messageID: message.id, in: conversationID)
                    handleNotFriends(for: conversation)
                } else if isSendPolicyForbidden(error) {
                    if isGroupMemberMutedError(error) {
                        markGroupMutedForConversation(conversation)
                    }
                    await refreshGroupPolicyAfterSendFailure(conversation, scope: scope)
                    guard isCurrentRemoteScope(scope) else { return }
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .cancelled)
                    handleRemoteError(error, fallback: "名片发送失败")
                    removeMessage(messageID: message.id, in: conversationID)
                } else {
                    await updateDurableOutbox(ticket: durableTicket, messageID: message.id, state: .retryWait)
                    markMessageFailed(messageID: message.id, in: conversationID)
                    handleRemoteError(error, fallback: "名片发送失败")
                }
            }
        }
    }

    func blockContact(_ user: IMUser) {
        guard canBlacklistByTenantPolicy else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前企业暂不允许拉黑")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态失效，请重新登录后拉黑")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        profileContactRevisionFence.rebind(scopeHash: scope)
        let mutationKeys = profileContactMutationKeys(for: user, kinds: ["blacklist", "contact"])
        guard let mutationTicket = profileContactRevisionFence.beginMutation(
            scopeHash: scope,
            keys: mutationKeys
        ) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态已变化，请重试拉黑")
            return
        }
        let previousContact = contacts.first { candidate in
            userIdentityCandidates(for: user).contains { self.user(candidate, matchesIdentifier: $0) }
        }
        let previousBlacklistItem = blacklist.first { $0.id == user.id }
        blacklist.removeAll { $0.id == user.id }
        blacklist.insert(BlacklistItem(id: user.id, name: user.name, reason: "用户主动拉黑"), at: 0)
        removeFriendData(user, removePrivateRemark: false)
        persistProfileContactProjectionIfPossible(
            scope: scope,
            revision: mutationTicket.revision,
            reason: "block_optimistic"
        )
        Task {
            do {
                let relation = try await api.addBlacklist(context: context, userID: user.id, reason: "用户主动拉黑")
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else { return }
                blacklist.removeAll { $0.id == user.id || $0.id == relation.blockedUID }
                blacklist.insert(BlacklistItem(id: relation.blockedUID, name: user.name, reason: relation.reason.isEmpty ? "用户主动拉黑" : relation.reason), at: 0)
                removeFriendData(user, removePrivateRemark: false)
                commitAuthoritativeProfileContactProjection(scope: scope, reason: "block_authoritative")
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已拉黑 \(user.name)")
                await refreshFriendApplicationsAndRelations(context: context, scope: scope)
            } catch {
                guard isCurrentRemoteScope(scope),
                      profileContactRevisionFence.isCurrent(mutationTicket) else { return }
                blacklist.removeAll { $0.id == user.id }
                if let previousBlacklistItem {
                    blacklist.insert(previousBlacklistItem, at: 0)
                }
                if let previousContact,
                   !contacts.contains(where: { $0.id == previousContact.id }) {
                    contacts.append(previousContact)
                }
                refreshDirectConversationDisplayNames()
                pruneNonFriendDirectConversations()
                commitAuthoritativeProfileContactProjection(scope: scope, reason: "block_rollback")
                handleRemoteError(error, fallback: "拉黑失败")
            }
        }
    }

    func deleteContact(_ user: IMUser) {
        guard canDeleteFriendByTenantPolicy else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前企业暂不允许删除好友")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录状态失效，请重新登录后删除好友")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                try await api.deleteFriend(context: context, userID: user.id)
                guard isCurrentRemoteScope(scope) else { return }
                removeFriendData(user)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已删除好友 \(user.name)")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if isDeleteFriendNotFoundError(error) {
                    removeFriendData(user)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已删除好友 \(user.name)")
                    return
                }
                handleRemoteError(error, fallback: "删除好友失败")
            }
        }
    }

    private func isDeleteFriendNotFoundError(_ error: Error) -> Bool {
        if case let IMAPIError.server(message) = error {
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "not found"
                || normalized == "not_found"
                || normalized.contains("friend_not_found")
                || normalized.contains("friend relation not found")
        }
        return false
    }

    func removeFriendData(_ user: IMUser, removePrivateRemark: Bool = true) {
        contacts.removeAll { $0.id == user.id }
        if removePrivateRemark {
            for key in contactRemarkKeys(for: user) {
                contactRemarks.removeValue(forKey: key)
            }
        }
        // Removing the relationship must retain readable direct-message history
        // and its participant snapshot. Send/call eligibility is enforced from
        // the authoritative friend relation instead of by deleting history.
        pruneNonFriendDirectConversations()
    }

    func isFriendID(_ id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return contacts.contains { $0.id == normalizedID || $0.userID == normalizedID }
    }

    func userIdentityCandidates(for user: IMUser) -> [String] {
        var seen = Set<String>()
        return [
            user.id,
            user.userID,
            user.username
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
    }

    func directPeerID(for conversation: ConversationMessageSnapshot) -> String? {
        guard conversation.kind == .direct else { return nil }
        let currentIDs = Set([
            currentUser.id.trimmingCharacters(in: .whitespacesAndNewlines),
            apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].filter { !$0.isEmpty })
        if let participant = conversation.participants.first(where: { user in
            let id = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && !currentIDs.contains(id)
        }) {
            return participant.id
        }
        let channelParts = conversation.id
            .split(separator: ":")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let peerID = channelParts.first(where: { !currentIDs.contains($0) }) {
            return peerID
        }
        return conversation.participants.first?.id
    }

    private func removeDirectConversation(withPeerID peerID: String) {
        conversationStore.removeDirectConversations(peerID: peerID) { [self] conversation in
            directPeerID(for: conversation)
        }
    }

    func pruneNonFriendDirectConversations() {
        guard contactStore.friendRelationsLoaded() else { return }
        let friendIDs = Set(contacts.map(\.id))
        for index in conversationStore.conversations.indices {
            let conversation = conversationStore.conversationMessageSnapshot(at: index)
            guard conversation.kind == .direct else { continue }
            guard let peerID = directPeerID(for: conversation) else {
                let context = DirectFriendRequestContext(
                    targetUID: "",
                    canApplyFriend: nil,
                    friendRequestStatus: "",
                    reasonCode: "friendship_required"
                )
                markDirectConversationUnavailable(conversation, context: context)
                continue
            }
            if friendIDs.contains(peerID) {
                conversationStore.setDirectDisabledMessage(conversationID: conversation.id, message: nil)
                conversationStore.clearDirectFriendRequestContext(conversationID: conversation.id)
                continue
            }
            let context = DirectFriendRequestContext(
                targetUID: peerID,
                canApplyFriend: nil,
                friendRequestStatus: "",
                reasonCode: "friendship_required"
            )
            markDirectConversationUnavailable(conversation, context: context)
        }
    }

    func conversationSendDisabledReason(_ conversationID: String) -> String {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return "" }
        return directSendBlockedMessage(for: conversation)
            ?? localSendPolicyBlockedMessage(for: conversation)
            ?? ""
    }

    func conversationFriendRequestActionTitle(_ conversationID: String) -> String? {
        guard canCurrentUserInitiateFriendRequest,
              let context = conversationStore.directFriendRequestContext(conversationID: conversationID),
              context.allowsApply else {
            return nil
        }
        return context.actionTitle
    }

    func applyFriendFromDisabledConversation(_ conversationID: String) async {
        guard !conversationStore.isApplyingFriend(conversationID: conversationID),
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else {
            return
        }
        let context = conversationStore.directFriendRequestContext(conversationID: conversationID)
        let targetUID = (context?.targetUID ?? directPeerID(for: conversation) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetUID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户信息不完整，无法添加好友")
            return
        }
        if conversation.participants.contains(where: { $0.id == targetUID && $0.isCancelledUser }) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该用户已注销，无法添加好友")
            return
        }
        guard canCurrentUserInitiateFriendRequest else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭好友申请")
            return
        }
        guard context?.allowsApply ?? false else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(context?.disabledMessage ?? "当前关系状态暂不可申请好友")
            return
        }
        let remoteContext = self.apiContext
        guard remoteContext.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: remoteContext)
        guard conversationStore.beginApplyingFriend(conversationID: conversationID) else { return }
        defer { conversationStore.finishApplyingFriend(conversationID: conversationID) }
        do {
            let applyResult = try await api.applyFriend(
                context: remoteContext,
                targetUID: targetUID,
                message: "你好，我想添加你为好友",
                source: "direct_chat_not_friends"
            )
            guard isCurrentRemoteScope(scope) else { return }
            let resolution = Self.friendApplyResolution(applyResult)
            if resolution == .established {
                conversationStore.setDirectDisabledMessage(conversationID: conversationID, message: nil)
                conversationStore.clearDirectFriendRequestContext(conversationID: conversationID)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(FriendAddPresentation.establishedMessage)
            } else if resolution == .pending {
                let pendingContext = DirectFriendRequestContext(
                    targetUID: targetUID,
                    canApplyFriend: false,
                    friendRequestStatus: "pending_out",
                    reasonCode: context?.reasonCode ?? "friendship_required",
                    friendAction: "none",
                    friendFlow: applyResult.friendFlow
                )
                markDirectConversationUnavailable(conversation, context: pendingContext)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(FriendAddPresentation.sentMessage)
            } else {
                let terminalContext = DirectFriendRequestContext(
                    targetUID: targetUID,
                    canApplyFriend: false,
                    friendRequestStatus: applyResult.relationStatus.isEmpty ? "history" : applyResult.relationStatus,
                    reasonCode: applyResult.outcome,
                    friendAction: applyResult.friendAction,
                    friendFlow: applyResult.friendFlow
                )
                markDirectConversationUnavailable(conversation, context: terminalContext)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(Self.isSuppressedFriendApplication(status: applyResult.status, outcome: applyResult.outcome)
                    ? FriendAddPresentation.suppressedMessage
                    : FriendAddPresentation.terminalMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            }
            _ = await refreshRemoteSnapshot(silent: true, force: true)
            if resolution == .established {
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            }
        } catch IMAPIError.conflict(let code, _) {
            guard isCurrentRemoteScope(scope) else { return }
            await refreshFriendApplicationsAndRelations(context: remoteContext, scope: scope)
            guard isCurrentRemoteScope(scope) else { return }
            if isFriendID(targetUID) {
                conversationStore.setDirectDisabledMessage(conversationID: conversationID, message: nil)
                conversationStore.clearDirectFriendRequestContext(conversationID: conversationID)
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            } else {
                let pendingContext = DirectFriendRequestContext(
                    targetUID: targetUID,
                    canApplyFriend: false,
                    friendRequestStatus: "pending_out",
                    reasonCode: context?.reasonCode ?? "friendship_required",
                    friendAction: "none",
                    friendFlow: context?.friendFlow ?? ""
                )
                markDirectConversationUnavailable(conversation, context: pendingContext)
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(Self.isFriendRelationChangedConflictCode(code)
                ? FriendAddPresentation.relationChangedMessage
                : FriendAddPresentation.sentMessage) /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            handleRemoteError(error, fallback: "好友申请失败")
        }
    }

    private func markDirectConversationUnavailable(_ conversation: ConversationMessageSnapshot, message: String) {
        let context = DirectFriendRequestContext(
            targetUID: directPeerID(for: conversation) ?? "",
            canApplyFriend: nil,
            friendRequestStatus: "",
            reasonCode: "friendship_required"
        )
        markDirectConversationUnavailable(conversation, context: context, fallbackMessage: message)
    }

    private func markDirectConversationUnavailable(_ conversation: ConversationMessageSnapshot, context: DirectFriendRequestContext, fallbackMessage: String? = nil) {
        conversationStore.markDirectConversationUnavailable(
            conversation,
            context: context,
            fallbackMessage: fallbackMessage
        )
    }

    func handleNotFriends(for conversation: ConversationMessageSnapshot, showToast: Bool = false) {
        handleNotFriends(
            for: conversation,
            context: DirectFriendRequestContext(
                targetUID: directPeerID(for: conversation) ?? "",
                canApplyFriend: nil,
                friendRequestStatus: "",
                reasonCode: "friendship_required"
            ),
            showToast: showToast
        )
    }

    func handleNotFriends(for conversation: ConversationMessageSnapshot, context: DirectFriendRequestContext, showToast _: Bool = false) {
        guard conversation.kind == .direct else {
            return
        }
        markDirectConversationUnavailable(conversation, context: context)
    }

    func directSendBlockedMessage(for conversation: ConversationMessageSnapshot) -> String? {
        if let message = conversationStore.directDisabledMessage(conversationID: conversation.id),
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if conversation.kind == .direct,
           conversation.participants.contains(where: { $0.isCancelledUser }) {
            return "该用户已注销，无法发送消息"
        }
        guard conversation.kind == .direct,
              let peerID = directPeerID(for: conversation),
              blacklist.contains(where: { $0.id == peerID }) else {
            return nil
        }
        return "你已拉黑对方，无法发送消息"
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

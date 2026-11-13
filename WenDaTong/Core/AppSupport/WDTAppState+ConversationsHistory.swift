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

// MARK: - Conversations and History

extension AppState {
    func conversation(id: String) -> ConversationMessageSnapshot {
        // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_BEGIN
        if let conversation = conversationStore.conversationMessagePresentation(id: id) {
            return conversation
        }
        // WDT_IOS1_REFACTOR_CHAT_CONVERSATION_OBSERVATION_20261110_END
        if let group = groups.first(where: { $0.id == id }) {
            return ConversationMessageSnapshot(
                id: group.id,
                title: group.name,
                subtitle: "群聊",
                kind: .group,
                lastMessage: group.notice,
                time: "",
                unread: 0,
                isPinned: false,
                isMuted: group.muted,
                memberCount: shouldShowGroupMemberCount ? group.effectiveMemberCount : nil,
                accentHex: stableSeed(group.id),
                participants: group.members,
                messages: [],
                avatarURL: group.avatarURL,
                avatarVersion: group.avatarVersion,
                avatarUpdatedAt: group.avatarUpdatedAt
            )
        }
        return ConversationMessageSnapshot(
            id: id,
            title: "会话同步中",
            subtitle: "",
            kind: .direct,
            lastMessage: "",
            time: "",
            unread: 0,
            isPinned: false,
            isMuted: false,
            memberCount: 0,
            accentHex: stableSeed(id),
            participants: [],
            messages: []
        )
    }

    // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_BEGIN
    func directConversationID(for user: IMUser, in availableConversations: [ConversationMessageSnapshot]? = nil) -> String? {
        let userIDs = Set(userIdentityCandidates(for: user))
        return (availableConversations ?? conversationStore.conversationMessageSnapshots()).first { conversation in
            // WDT_IOS1_REFACTOR_CONVERSATION_TARGET_OBSERVATION_20261110_END
            guard conversation.kind == .direct else { return false }
            if conversation.participants.contains(where: { participant in
                userIDs.contains(participant.id.trimmingCharacters(in: .whitespacesAndNewlines))
                    || userIDs.contains(participant.userID.trimmingCharacters(in: .whitespacesAndNewlines))
            }) {
                return true
            }
            return conversation.id
                .split(separator: ":")
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains { userIDs.contains($0) }
        }?.id
    }

    func canStartDirectConversation(with user: IMUser) -> Bool {
        guard !isCancelledProfile(user) else { return false }
        return userIdentityCandidates(for: user).contains { isFriendID($0) }
    }

    func canStartVoiceCall(with user: IMUser) -> Bool {
        voiceCallUnavailableReason(for: user) == nil
    }

    func callLicenseScopeKey(for context: IMAPIContext) -> String {
        [
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            IMAPIContext.normalizedIOSAppID(context.appID),
            context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
    }

    private var hasAuthoritativeCallLicenseForCurrentScope: Bool {
        apiContext.hasIMSession
            && fileStore.uploadConfiguration.callLicenseScopeKey == callLicenseScopeKey(for: apiContext) // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110
    }

    var isVoiceCallLicensedForCurrentTenant: Bool {
        hasAuthoritativeCallLicenseForCurrentScope
            && fileUploadConfig.voiceCallLicenseKnown && fileUploadConfig.voiceCallEnabled
    }

    var isVideoCallLicensedForCurrentTenant: Bool {
        hasAuthoritativeCallLicenseForCurrentScope
            && fileUploadConfig.videoCallLicenseKnown && fileUploadConfig.videoCallEnabled
    }

    func callLicenseUnavailableMessage(for media: RTCCapabilityMedia) -> String? {
        let known = media == .video ? fileUploadConfig.videoCallLicenseKnown : fileUploadConfig.voiceCallLicenseKnown
        guard hasAuthoritativeCallLicenseForCurrentScope, known else {
            return rtcCapabilityFailureMessage(code: "rtc_license_capabilities_unavailable", media: media)
        }
        let enabled = media == .video ? fileUploadConfig.videoCallEnabled : fileUploadConfig.voiceCallEnabled
        return enabled ? nil : rtcCapabilityFailureMessage(
            code: media == .video ? "video_call_not_enabled" : "voice_call_not_enabled", media: media
        )
    }

    @discardableResult
    func guardCallLicenseForAction(_ media: RTCCapabilityMedia) -> Bool {
        guard let message = callLicenseUnavailableMessage(for: media) else { return true }
        rtcCapabilityAlertStore.message = message // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
        return false
    }

    func callLicenseActionGeneration(for media: RTCCapabilityMedia) -> UInt64 {
        directCallCapabilityGeneration(for: media == .video ? .video : .voice)
    }

    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
    func directConversationCallPeer(for conversation: ConversationMessageSnapshot, directoryContacts: [IMUser]? = nil) -> IMUser? {
        var currentIdentityIDs = Set(userIdentityCandidates(for: currentUser))
        if let imUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !imUID.isEmpty {
            currentIdentityIDs.insert(imUID)
        }
        guard let peer = DirectConversationCallPeerResolver.resolve(
            conversation: conversation.conversation,
            currentIdentityIDs: currentIdentityIDs,
            contacts: directoryContacts ?? contacts
        ), !isCurrentUserProfile(peer) else {
            return nil
        }
        return peer
    }
    // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END

    func directConversationCertificationUID(for conversation: ConversationMessageSnapshot) -> String? {
        guard conversation.kind == .direct else { return nil }
        return directConversationCertificationUID(
            for: conversation,
            resolvedPeer: directConversationCallPeer(for: conversation)
        )
    }

    func directConversationCertificationUID(for conversation: ConversationMessageSnapshot, resolvedPeer: IMUser?) -> String? {
        guard conversation.kind == .direct else { return nil }
        let currentIDs = currentUserIdentitySet()

        if let peer = resolvedPeer,
           let uid = userIdentityCandidates(for: peer).first(where: { !currentIDs.contains($0) }) {
            return uid
        }

        if let uid = firstUniqueDirectPeerID(
            conversation.participants.map(\.id),
            currentIDs: currentIDs
        ) {
            return uid
        }

        if let uid = firstUniqueDirectPeerID(
            directChannelParts(remoteChannelID(for: conversation)) + directChannelParts(conversation.id),
            currentIDs: currentIDs
        ) {
            return uid
        }

        return conversation.messages.reversed().lazy
            .map(\.senderId)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !currentIDs.contains($0) }
    }

    func directConversationProfilePeer(
        for conversation: ConversationMessageSnapshot,
        contactLookup: DirectConversationCallPeerResolver.ContactLookup? = nil
    ) -> IMUser? {
        var currentIdentityIDs = Set(userIdentityCandidates(for: currentUser))
        if let imUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !imUID.isEmpty {
            currentIdentityIDs.insert(imUID)
        }
        guard let peer = DirectConversationProfilePeerResolver.resolve(
            conversation: conversation,
            currentIdentityIDs: currentIdentityIDs,
            contacts: contacts,
            fallbackEnterprise: currentEnterprise.name,
            contactLookup: contactLookup
        ), !isCurrentUserProfile(peer) else {
            return nil
        }
        return peer
    }

    private func firstUniqueDirectPeerID(
        _ rawIDs: [String],
        currentIDs: Set<String>
    ) -> String? {
        var seen = Set<String>()
        let peerIDs = rawIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !currentIDs.contains($0) }
            .filter { seen.insert($0).inserted }
        return peerIDs.count == 1 ? peerIDs[0] : nil
    }

    func canStartVideoCall(with user: IMUser) -> Bool {
        videoCallUnavailableReason(for: user) == nil
    }

    func videoCallUnavailableReason(for user: IMUser) -> String? {
        callLicenseUnavailableMessage(for: .video) ?? videoCallEntryUnavailableReason(for: user)
    }

    func videoCallEntryUnavailableReason(for user: IMUser) -> String? {
        if isCurrentUserProfile(user) { return "不能和自己发起视频通话" }
        if isCancelledProfile(user) { return "该用户已注销，无法发起视频通话" }
        if isBlockedProfile(user) { return "已拉黑该用户，解除后才能发起视频通话" }
        guard videoMediaClient.isAvailable else { return videoMediaClientUnavailableReason }
        if userIdentityCandidates(for: user).contains(where: { isFriendID($0) }) { return nil }
        // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
        if contactStore.friendRelationsPending {
            return "好友关系同步中，请稍后再试"
        }
        return "需先添加好友后才能发起视频通话"
    }

    func voiceCallUnavailableReason(for user: IMUser) -> String? {
        if isCurrentUserProfile(user) {
            return "不能和自己发起语音通话"
        }
        if isCancelledProfile(user) {
            return "该用户已注销，无法发起语音通话"
        }
        if isBlockedProfile(user) {
            return "已拉黑该用户，解除后才能发起语音通话"
        }
        if userIdentityCandidates(for: user).contains(where: { isFriendID($0) }) {
            return isVoiceMediaClientAvailable ? nil : voiceMediaClientUnavailableReason
        }
        // WDT_IOS1_REFACTOR_CONTACT_SYNC_OBSERVATION_20261110
        if contactStore.friendRelationsPending {
            return "好友关系同步中，请稍后再试"
        }
        guard canStartDirectConversation(with: user) else {
            return "需先添加好友后才能发起语音通话"
        }
        return nil
    }

    func incomingVoiceCallUnavailableReason(for user: IMUser) -> String? {
        if isCurrentUserProfile(user) {
            return "不能接听自己的语音通话"
        }
        if isCancelledProfile(user) {
            return "该用户已注销，无法接听语音通话"
        }
        if isBlockedProfile(user) {
            return "已拉黑该用户，解除后才能接听语音通话"
        }
        if !isVoiceMediaClientAvailable {
            return voiceMediaClientUnavailableReason
        }
        return nil
    }

    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
    func hasPendingOutgoingFriendRequest(with user: IMUser) -> Bool {
        contactStore.hasPendingOutgoingFriendRequest(identities: Set(userIdentityCandidates(for: user)))
    }
    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END

    func isCurrentUserProfile(_ user: IMUser) -> Bool {
        let currentIDs = currentUserIdentitySet()
        return userIdentityCandidates(for: user).contains { currentIDs.contains($0) }
    }

    func isCancelledProfile(_ user: IMUser) -> Bool {
        user.isCancelledUser
    }

    func isBlockedProfile(_ user: IMUser) -> Bool {
        let candidates = userIdentityCandidates(for: user)
        return blacklist.contains { item in
            candidates.contains(item.id.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func openOrCreateDirectConversationID(for user: IMUser, activateChatsTab: Bool = true) -> String? {
        let peerID = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("用户信息不完整，无法发起会话")
            return nil
        }
        if peerID == currentUser.id || peerID == apiContext.imUID {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("不能和自己发起会话")
            return nil
        }
        if isCancelledProfile(user) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该用户已注销，无法发起私聊")
            return nil
        }
        guard isFriendID(peerID) else {
            return nil
        }
        let groupScopedIdentityIDs = Set(userIdentityCandidates(for: user))
        let directUser = contacts.first { contact in
            !Set(userIdentityCandidates(for: contact)).isDisjoint(with: groupScopedIdentityIDs)
        } ?? user
        let selfID = apiContext.imUID ?? currentUser.id
        let channelID = [selfID, peerID].sorted().joined(separator: ":")
        if apiContext.hasIMSession {
            clearLocalHiddenConversation(
                channelID: channelID,
                channelType: "direct",
                scope: remoteDataScopeKey(for: apiContext)
            )
        }
        if let existingID = directConversationID(for: directUser) {
            if activateChatsTab {
                activeTab = .chats
            }
            syncConversationMessagesIfNeeded(existingID, force: true, silent: true)
            return existingID
        }

        guard let conversation = conversationStore.insertDirectConversation(
            channelID: channelID,
            title: directUser.displayName,
            participant: directUser,
            accentHex: stableSeed(peerID)
        ) else { return nil }
        if activateChatsTab {
            activeTab = .chats
        }
        syncConversationMessagesIfNeeded(conversation.id, force: true, silent: true)
        return conversation.id
    }

    func markConversationRead(_ conversationID: String, throughSeq: Int64? = nil, showToast: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard let index = conversationStore.conversations.firstIndex(where: { $0.id == conversationID }) else {
            completion?(false)
            return
        }
        let conversation = conversationStore.conversationMessageSnapshot(at: index)
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            }
            completion?(false)
            return
        }
        let readAckSyncKey = conversationReadStateKey(
            channelID: remoteChannelID(for: conversation),
            channelType: apiChannelType(for: conversation.kind)
        )
        let latestReadSeq = latestReadableSequence(in: conversation)
        let readAckTargetSeq = throughSeq.map { min(latestReadSeq, max(0, $0)) } ?? latestReadSeq
        let readAckPlan = conversationStore.readAckSyncPlan(
            syncKey: readAckSyncKey,
            targetSeq: readAckTargetSeq > 0 ? readAckTargetSeq : nil
        )
        let readAckCommand: ConversationStore.ReadAckCommand
        switch readAckPlan {
        case .clearLocally:
            if throughSeq != nil {
                conversationStore.advanceRead(conversationID: conversationID, through: readAckTargetSeq)
            } else {
                clearConversationUnreadLocally(conversationID)
            }
            let effectiveReadSeq = rememberConversationReadLocally(conversation, through: readAckTargetSeq)
            cancelLocalNotificationsForCurrentRead(
                channelID: remoteChannelID(for: conversation),
                channelType: apiChannelType(for: conversation.kind),
                throughSeq: effectiveReadSeq
            )
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已标记为已读")
            }
            completion?(true)
            return
        case .remoteAck(let command):
            readAckCommand = command
        case .queue(let command):
            _ = conversationStore.queueReadAckSync(command)
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在同步已读状态")
            }
            completion?(false)
            return
        case .skip:
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在同步已读状态")
            }
            completion?(false)
            return
        }
        guard let readAckClaim = conversationStore.beginReadAckSyncClaim(readAckCommand) else {
            if showToast {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在同步已读状态")
            }
            completion?(false)
            return
        }
        if showToast {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在同步已读状态")
        }
        Task {
            defer {
                if let queued = conversationStore.finishReadAckSync(readAckClaim),
                   isCurrentRemoteScope(scope) {
                    // Preserve the requested watermark: newer messages may not
                    // have been displayed while the previous ACK was in flight.
                    markConversationRead(conversationID, throughSeq: queued.targetSeq, showToast: false)
                }
            }
            do {
                let shouldClearLocal: Bool
                var confirmedReadSeq: Int64? = nil
                if conversation.kind == .system {
                    let inboxRead = try await api.markSystemInboxRead(context: context)
                    guard isCurrentRemoteScope(scope) else {
                        completion?(false)
                        return
                    }
                    let responseChannelID = inboxRead.imReadAck?.channelID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let ackChannelID = normalizedRemoteChannelID(
                        responseChannelID.isEmpty ? remoteChannelID(for: conversation) : responseChannelID,
                        channelType: inboxRead.imReadAck?.channelType ?? apiChannelType(for: conversation.kind)
                    )
                    let ackTargetSeq = latestReadableSequence(in: conversation)
                    let ackResponse = try? await api.readAck(
                        context: context,
                        conversation: conversation,
                        channelID: ackChannelID,
                        throughSeq: ackTargetSeq
                    )
                    guard isCurrentRemoteScope(scope) else {
                        completion?(false)
                        return
                    }
                    if let ackResponse {
                        applyRemoteReadReceipts(ackResponse.readReceipts, channelID: ackResponse.channelID.isEmpty ? ackChannelID : ackResponse.channelID)
                    }
                    if let imReadAck = inboxRead.imReadAck {
                        applyRemoteReadReceipts(imReadAck.receipts, channelID: ackChannelID)
                    }
                    let effectiveReadSeq = rememberConversationReadLocally(conversation)
                    rememberSystemInboxReadAck(inboxRead.imReadAck, fallback: conversation)
                    markSystemInboxReadLocally()
                    cancelLocalNotificationsForCurrentRead(
                        channelID: ackChannelID,
                        channelType: apiChannelType(for: conversation.kind),
                        throughSeq: effectiveReadSeq
                    )
                    await refreshInboxSilently()
                    guard isCurrentRemoteScope(scope) else {
                        completion?(false)
                        return
                    }
                    _ = await refreshRemoteSnapshot(silent: true, force: true)
                    guard isCurrentRemoteScope(scope) else {
                        completion?(false)
                        return
                    }
                    shouldClearLocal = true
                } else {
                    let ackChannelID = remoteChannelID(for: conversation)
                    let requestedReadSeq = readAckTargetSeq
                    let ticket = try await prepareDurableReadAckTicket(
                        conversation: conversation,
                        context: context,
                        scope: scope,
                    )
                    let ackTargetSeq = try await messagePersistence.recordAckDesired(
                        ticket: ticket,
                        channelKey: ackChannelID,
                        type: "read",
                        desiredSeq: requestedReadSeq,
                        resetRetryBudget: true
                    )
                    guard ackTargetSeq > 0 else {
                        completion?(false)
                        return
                    }
                    let claimed = try await messagePersistence.claimAcksForRetry(
                        ticket: ticket,
                        type: "read",
                        channelKey: ackChannelID,
                        limit: 1
                    )
                    guard let durableAck = claimed.first,
                          isCurrentRemoteScope(scope) else {
                        scheduleDurableReadAckRecovery(ticket: ticket)
                        completion?(false)
                        return
                    }
                    shouldClearLocal = await sendDurableReadAck(
                        durableAck,
                        ticket: ticket,
                        conversation: conversation,
                        context: context,
                        scope: scope
                    )
                    if shouldClearLocal {
                        confirmedReadSeq = durableAck.desiredSeq
                    } else {
                        scheduleDurableReadAckRecovery(ticket: ticket)
                    }
                }
                if shouldClearLocal {
                    if let confirmedReadSeq {
                        conversationStore.advanceRead(conversationID: conversationID, through: confirmedReadSeq)
                    } else {
                        clearConversationUnreadLocally(conversationID)
                    }
                }
                if showToast {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(shouldClearLocal ? "已标记为已读" : "已提交已读，等待服务端刷新")
                }
                completion?(shouldClearLocal)
            } catch {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    handleRemoteError(error, fallback: "已读状态同步失败", silent: !showToast)
                }
                completion?(false)
            }
        }
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

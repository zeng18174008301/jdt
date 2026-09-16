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

// MARK: - Conversations and History

extension AppState {
    func conversation(id: String) -> Conversation {
        if let conversation = conversations.first(where: { $0.id == id }) {
            return conversation
        }
        if conversationKind(from: "", channelID: id) == .system,
           let systemConversation = conversations.first(where: { $0.kind == .system }) {
            return systemConversation
        }
        if let group = groups.first(where: { $0.id == id }) {
            return Conversation(
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
        return Conversation(
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

    func directConversationID(for user: IMUser) -> String? {
        let userIDs = Set(userIdentityCandidates(for: user))
        return conversations.first { conversation in
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
            && authoritativeCallLicenseScopeKey == callLicenseScopeKey(for: apiContext)
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
        rtcCapabilityAlertMessage = message
        return false
    }

    func callLicenseActionGeneration(for media: RTCCapabilityMedia) -> UInt64 {
        directCallCapabilityGeneration(for: media == .video ? .video : .voice)
    }

    func directConversationCallPeer(for conversation: Conversation) -> IMUser? {
        var currentIdentityIDs = Set(userIdentityCandidates(for: currentUser))
        if let imUID = apiContext.imUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !imUID.isEmpty {
            currentIdentityIDs.insert(imUID)
        }
        guard let peer = DirectConversationCallPeerResolver.resolve(
            conversation: conversation,
            currentIdentityIDs: currentIdentityIDs,
            contacts: contacts
        ), !isCurrentUserProfile(peer) else {
            return nil
        }
        return peer
    }

    func directConversationCertificationUID(for conversation: Conversation) -> String? {
        guard conversation.kind == .direct else { return nil }
        return directConversationCertificationUID(
            for: conversation,
            resolvedPeer: directConversationCallPeer(for: conversation)
        )
    }

    func directConversationCertificationUID(for conversation: Conversation, resolvedPeer: IMUser?) -> String? {
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
        for conversation: Conversation,
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
        if isContactsSyncing || (!contactStore.friendRelationsLoaded() && contacts.isEmpty) {
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
        if isContactsSyncing || (!contactStore.friendRelationsLoaded() && contacts.isEmpty) {
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

    func hasPendingOutgoingFriendRequest(with user: IMUser) -> Bool {
        let candidates = Set(userIdentityCandidates(for: user))
        guard !candidates.isEmpty else { return false }
        return friendRequests.contains { request in
            let peerID = request.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let direction = request.direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return direction == "outgoing" && status == "pending" && candidates.contains(peerID)
        }
    }

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
            toast = "用户信息不完整，无法发起会话"
            return nil
        }
        if peerID == currentUser.id || peerID == apiContext.imUID {
            toast = "不能和自己发起会话"
            return nil
        }
        if isCancelledProfile(user) {
            toast = "该用户已注销，无法发起私聊"
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
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            completion?(false)
            return
        }
        let conversation = conversations[index]
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else {
            if showToast {
                toast = "登录会话不可用，请重新登录"
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
                toast = "已标记为已读"
            }
            completion?(true)
            return
        case .remoteAck(let command):
            readAckCommand = command
        case .queue(let command):
            _ = conversationStore.queueReadAckSync(command)
            if showToast {
                toast = "正在同步已读状态"
            }
            completion?(false)
            return
        case .skip:
            if showToast {
                toast = "正在同步已读状态"
            }
            completion?(false)
            return
        }
        guard let readAckClaim = conversationStore.beginReadAckSyncClaim(readAckCommand) else {
            if showToast {
                toast = "正在同步已读状态"
            }
            completion?(false)
            return
        }
        if showToast {
            toast = "正在同步已读状态"
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
                    toast = shouldClearLocal ? "已标记为已读" : "已提交已读，等待服务端刷新"
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

    func clearConversationUnreadLocally(_ conversationID: String) {
        conversationStore.clearUnread(conversationID: conversationID) { channelID in
            conversationKind(from: "", channelID: channelID) == .system
        }
    }

    @discardableResult
    func rememberConversationReadLocally(_ conversation: Conversation, through confirmedSeq: Int64? = nil) -> Int64 {
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let readSeq = confirmedSeq ?? latestReadableSequence(in: conversation)
        guard !channelID.isEmpty, readSeq > 0 else { return 0 }
        let key = conversationReadStateKey(channelID: channelID, channelType: channelType)
        if let scope = currentReadWatermarkScope(channelID: channelID, channelType: channelType),
           let watermark = ConversationStore.ReadWatermark(
            eventID: "",
            tenantID: scope.tenantID,
            imUID: scope.imUID,
            appID: scope.appID,
            channelID: scope.channelID,
            channelType: scope.channelType,
            lastReadSeq: readSeq
           ) {
            let effectiveReadSeq = conversationStore.rememberReadWatermark(watermark)
            conversationStore.rememberRead(key: key, readSeq: effectiveReadSeq)
            return max(effectiveReadSeq, conversationStore.locallyReadSeq(forKey: key))
        }
        conversationStore.rememberRead(key: key, readSeq: readSeq)
        return conversationStore.locallyReadSeq(forKey: key)
    }

    func cancelLocalNotificationsForCurrentRead(channelID: String, channelType: String, throughSeq: Int64) {
        guard throughSeq > 0,
              let scope = currentReadWatermarkScope(channelID: channelID, channelType: channelType) else { return }
        cancelLocalNotifications(for: scope, throughSeq: throughSeq)
    }

    private func rememberSystemInboxReadAck(_ ack: RemoteIMReadAckTarget?, fallback conversation: Conversation) {
        let channelType = ack?.channelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? ack!.channelType
            : apiChannelType(for: conversation.kind)
        let channelID = ack?.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? ack!.channelID
            : remoteChannelID(for: conversation)
        let readSeq = max(ack?.lastRead ?? 0, latestReadableSequence(in: conversation))
        guard !channelID.isEmpty, readSeq > 0 else { return }
        let key = conversationReadStateKey(channelID: channelID, channelType: channelType)
        if let scope = currentReadWatermarkScope(channelID: channelID, channelType: channelType),
           let watermark = ConversationStore.ReadWatermark(
            eventID: "",
            tenantID: scope.tenantID,
            imUID: scope.imUID,
            appID: scope.appID,
            channelID: scope.channelID,
            channelType: scope.channelType,
            lastReadSeq: readSeq
           ) {
            let effectiveReadSeq = conversationStore.rememberReadWatermark(watermark)
            conversationStore.rememberRead(key: key, readSeq: effectiveReadSeq)
        } else {
            conversationStore.rememberRead(key: key, readSeq: readSeq)
        }
    }

    func latestReadableSequence(in conversation: Conversation) -> Int64 {
        conversationStore.latestReadableSequence(in: conversation)
    }

    func conversationReadStateKey(channelID: String, channelType: String) -> String {
        conversationStore.conversationReadStateKeyContext(
            channelID: channelID,
            channelType: channelType,
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizedRemoteChannelID(rawChannelID, channelType: rawChannelType)
            }
        ).syncKey
    }

    func isConversationLocallyReadThrough(_ remote: RemoteConversation) -> Bool {
        guard remote.lastMsgSeq > 0 else { return false }
        let key = conversationReadStateKey(channelID: remote.channelID, channelType: remote.channelType)
        return conversationStore.isLocallyReadThrough(key: key, lastMessageSeq: remote.lastMsgSeq)
    }

    func locallyReadSeq(for remote: RemoteConversation) -> Int64 {
        let key = conversationReadStateKey(channelID: remote.channelID, channelType: remote.channelType)
        return conversationStore.locallyReadSeq(forKey: key)
    }

    func syncConversationMessagesIfNeeded(
        _ conversationID: String,
        force: Bool = false,
        silent: Bool = false,
        showLoadingIndicator: Bool = true,
        trimToLatestWindow: Bool = false,
        authRecoveryAllowed: Bool = true
    ) {
        guard apiContext.hasIMSession else {
            if !silent {
                toast = "登录会话不可用，请重新登录"
            }
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let selectionToken = conversationSelectionEpochFence.token(
            scope: scope,
            conversationID: conversationID
        )
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let latestHistoryWindowLimit = latestConversationMessageWindowLimit
        let windowRetention: ConversationStore.MessageWindowRetention = trimToLatestWindow
            ? .latestTail(limit: latestHistoryWindowLimit)
            : .preserveLoadedHistory
        let historyKey = conversationHistoryStateKey(for: conversation)
        let syncPlan = conversationStore.messageSyncPlan(
            for: conversation,
            historyKey: historyKey,
            force: force,
            latestHistoryWindowLimit: latestHistoryWindowLimit
        )
        if syncPlan == .sidecarsOnly {
            Task {
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            }
            return
        }
        guard case .remoteHistory(let plannedHistoryKey, let syncWindows) = syncPlan else { return }
        guard conversationStore.beginMessageSync(
            historyKey: plannedHistoryKey,
            conversationID: conversationID,
            showLoadingIndicator: showLoadingIndicator
        ) else {
            return
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let cachedMessageCount = conversation.messages.count
        Task {
            var diagnostic: SyncFailureDiagnostic.HTTPObservation?
            defer {
                conversationStore.finishMessageSync(
                    historyKey: plannedHistoryKey,
                    conversationID: conversationID,
                    showLoadingIndicator: showLoadingIndicator
                )
            }
            do {
                var messages: [RemoteMessage] = []
                var syncBoundary: ConversationStore.HistoryVisibilityBoundary?
                for window in syncWindows {
                    let requestDiagnostic = SyncFailureDiagnostic.HTTPObservation(.history)
                    diagnostic = requestDiagnostic
                    let page = try await SyncFailureDiagnostic.$httpObservation.withValue(requestDiagnostic) {
                        defer { requestDiagnostic.finish() }
                        return try await requestDiagnostic.perform {
                            try await api.syncMessages(
                                context: context, channelID: channelID, channelType: channelType,
                                afterSeq: window.afterSeq, limit: window.limit
                            )
                        }
                    }
                    guard selectionToken.map({ conversationSelectionEpochFence.accepts($0) }) ?? true else { return }
                    guard isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                    syncBoundary = historyBoundary(from: page, channelType: channelType) ?? syncBoundary
                    messages.append(contentsOf: page.items)
                }
                guard isCurrentRemoteRefresh(refreshSession, scope: scope),
                      selectionToken.map({ conversationSelectionEpochFence.accepts($0) }) ?? true else { return }
                clearSyncFailureDiagnostics(for: .history)
                if messages.isEmpty {
                    if let syncBoundary {
                        applyHistoryVisibilityBoundaryForGroup(
                            channelID: channelID,
                            boundary: syncBoundary
                        )
                    }
                    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                    print("[JHT Perf] chat_history_ready_ms=\(elapsedMs) remote_messages=0 cached_messages=\(cachedMessageCount) forced=\(force) loading=\(showLoadingIndicator)")
                    if showLoadingIndicator || conversation.messages.isEmpty {
                        conversationStore.setHistoryMessage(
                            conversationID: conversationID,
                            message: syncBoundary?.isRestrictive == true ? groupHistoryLimitedMessage : (conversation.messages.isEmpty ? "暂无历史消息" : nil)
                        )
                    }
                    // Reading history does not establish a friendship or grant sending rights.
                    await syncReadReceiptsForConversation(channelID: channelID, channelType: channelType, session: sidecarSession)
                    return
                }
                applyRemoteMessages(
                    messages,
                    channelID: channelID,
                    channelType: channelType,
                    windowRetention: windowRetention,
                    historyBoundary: syncBoundary,
                    sequenceCoverageAfterSeq: syncWindows.map(\.afterSeq).min()
                )
                conversationStore.setHistoryMessage(conversationID: conversationID, message: nil)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                print("[JHT Perf] chat_history_ready_ms=\(elapsedMs) remote_messages=\(messages.count) cached_messages=\(cachedMessageCount) forced=\(force) loading=\(showLoadingIndicator)")
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            } catch {
                guard selectionToken.map({ conversationSelectionEpochFence.accepts($0) }) ?? true else { return }
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                print("[JHT Perf] chat_history_failed_ms=\(elapsedMs) cached_messages=\(cachedMessageCount) forced=\(force) loading=\(showLoadingIndicator)")
                if isNotFriendsError(error) {
                    recordSyncFailureDiagnostic(error, endpoint: .history, httpFailure: diagnostic?.failure)
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    if showLoadingIndicator {
                        conversationStore.setHistoryMessage(conversationID: conversationID, message: "聊天记录同步失败，请稍后重试")
                    }
                    handleConversationHistorySyncError(
                        error,
                        conversationID: conversationID,
                        silent: silent,
                        authRecoveryAllowed: authRecoveryAllowed,
                        httpFailure: diagnostic?.failure
                    )
                }
            }
        }
    }

    func prepareConversationTailWindowForEntry(_ conversationID: String) {
        conversationStore.trimConversationToLatestWindow(
            conversationID: conversationID,
            limit: latestConversationMessageWindowLimit
        )
    }

    private func handleConversationHistorySyncError(
        _ error: Error,
        conversationID: String,
        silent: Bool,
        authRecoveryAllowed: Bool,
        httpFailure: SyncFailureDiagnostic.Failure? = nil
    ) {
        let unauthorized = isUnauthorizedError(error)
        let deviceRevoked = unauthorized && DeviceRevocationDetector.matches(error: error)
        let recovery: SyncFailureDiagnostic.Recovery = !unauthorized ? .notApplicable
            : deviceRevoked ? .deviceRevoked
            : !authRecoveryAllowed ? .notAllowed
            : !apiContext.hasRefreshSession ? .noRefreshAuthority : .attempted
        recordSyncFailureDiagnostic(error, endpoint: .history, recovery: recovery, httpFailure: httpFailure)
        if unauthorized, !deviceRevoked {
            let context = apiContext
            let scope = remoteDataScopeKey(for: context)
            applySyncFailure(error, silent: silent)
            if !silent {
                showRemoteErrorToast("聊天记录同步失败：登录状态暂时无法验证，请稍后重试")
            }
            guard authRecoveryAllowed, context.hasRefreshSession else {
                logSyncEndpointFailure("/api/im/sync", error: error)
                return
            }
            Task { [weak self, context, scope] in
                guard let self else { return }
                let refreshed = await self.refreshStoredAuthSessionIfNeeded(
                    reason: "conversation_history",
                    silent: true,
                    context: context,
                    scope: scope
                )
                guard refreshed,
                      self.isAuthenticated,
                      self.isCurrentRemoteScope(scope) else { return }
                await Task.yield()
                self.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: false,
                    trimToLatestWindow: false,
                    authRecoveryAllowed: false
                )
            }
            return
        }
        if silent {
            logSyncEndpointFailure("/api/im/sync", error: error)
            if workspaceAccessCode(from: error) != nil || isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "聊天记录同步失败", silent: false)
            }
            return
        }
        guard conversationStore.shouldShowHistorySyncErrorToast(conversationID: conversationID) else {
            logSyncEndpointFailure("/api/im/sync", error: error)
            return
        }
        handleRemoteError(error, fallback: "聊天记录同步失败")
    }

    var groupHistoryLimitedMessage: String {
        groupHistoryLimitedMessageText
    }

    private func historyLimitedReachedStartMessage(for conversation: Conversation) -> String {
        if conversation.kind == .group,
           let boundary = conversationStore.historyBoundary(for: conversation),
           boundary.isRestrictive {
            return groupHistoryLimitedMessage
        }
        return conversation.messages.isEmpty ? "暂无历史消息" : "已同步到最早消息"
    }

    func historyBoundary(from result: RemoteMessageSyncResult, channelType: String) -> ConversationStore.HistoryVisibilityBoundary? {
        guard channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "group" else { return nil }
        return ConversationStore.HistoryVisibilityBoundary(
            fromSeq: result.historyVisibleFromSeq,
            limited: result.historyLimited,
            confirmed: true
        )
    }

    func historyBoundary(from remote: RemoteConversation, kind: ConversationKind) -> ConversationStore.HistoryVisibilityBoundary? {
        guard kind == .group else { return nil }
        return ConversationStore.HistoryVisibilityBoundary(
            fromSeq: remote.historyVisibleFromSeq,
            limited: remote.historyLimited,
            confirmed: true
        )
    }

    private func historyBoundaryForGroupChannelID(_ rawChannelID: String) -> ConversationStore.HistoryVisibilityBoundary? {
        let channelID = rawChannelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else { return nil }
        if let conversation = conversations.first(where: { conversation in
            conversation.kind == .group && (conversation.id == channelID || remoteChannelID(for: conversation) == channelID)
        }) {
            return conversationStore.historyBoundary(for: conversation)
        }
        if let group = group(id: channelID),
           group.historyLimited || group.historyVisibleFromSeq > 1 {
            return ConversationStore.HistoryVisibilityBoundary(
                fromSeq: group.historyVisibleFromSeq,
                limited: group.historyLimited,
                confirmed: true
            )
        }
        return nil
    }

    func isRemoteMessageVisibleAfterHistoryBoundary(_ remote: RemoteMessage, boundary: ConversationStore.HistoryVisibilityBoundary?) -> Bool {
        guard let boundary, boundary.isRestrictive else { return true }
        return remote.channelSeq >= boundary.fromSeq
    }

    private func isFileItemVisibleAfterHistoryBoundary(_ file: FileItem) -> Bool {
        let channelType = file.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channelType == "group",
              let boundary = historyBoundaryForGroupChannelID(file.channelID),
              boundary.isRestrictive else { return true }
        return file.channelSeq >= boundary.fromSeq
    }

    func isFileItemVisibleInFileLists(_ file: FileItem) -> Bool {
        !file.isVoiceMessageAsset && isFileItemVisibleAfterHistoryBoundary(file)
    }

    func isFavoriteAssetVisibleAfterHistoryBoundary(_ item: FavoriteAssetItem) -> Bool {
        let channelType = item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channelType == "group",
              let boundary = historyBoundaryForGroupChannelID(item.channelID),
              boundary.isRestrictive else { return true }
        return item.channelSeq >= boundary.fromSeq
    }

    @discardableResult
    func applyHistoryVisibilityBoundaryForGroup(
        channelID: String,
        boundary: ConversationStore.HistoryVisibilityBoundary
    ) -> Bool {
        pruneDerivedCachesForHistoryBoundary(channelID: channelID, boundary: boundary)
        return conversationStore.applyHistoryVisibilityBoundary(
            channelID: channelID,
            boundary: boundary,
            channelIDForConversation: { remoteChannelID(for: $0) }
        )
    }

    func pruneDerivedCachesForHistoryBoundary(
        channelID: String,
        boundary: ConversationStore.HistoryVisibilityBoundary
    ) {
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelID.isEmpty else { return }
        let previousBoundary = historyBoundaryForGroupChannelID(normalizedChannelID)
        let shouldClearForNewEpisode = previousBoundary.map { boundary.fromSeq < $0.fromSeq } ?? false
        guard shouldClearForNewEpisode || boundary.isRestrictive else { return }

        fileStore.purgeGroupHistoryFiles(
            groupID: normalizedChannelID,
            fromSeq: boundary.fromSeq,
            clearAll: shouldClearForNewEpisode
        )
        favoriteAssets.removeAll { item in
            let channelType = item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let itemChannelID = item.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channelType == "group", itemChannelID == normalizedChannelID else { return false }
            if shouldClearForNewEpisode { return true }
            return item.channelSeq <= 0 || item.channelSeq < boundary.fromSeq
        }
        let scope = remoteDataScopeKey(for: apiContext)
        favoriteAssetsCollection.remove(scope: scope) { item in
            let channelType = item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let itemChannelID = item.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channelType == "group", itemChannelID == normalizedChannelID else { return false }
            if shouldClearForNewEpisode { return true }
            return item.channelSeq <= 0 || item.channelSeq < boundary.fromSeq
        }
        favoriteAssets = favoriteAssetsCollection.activeItems

        guard let conversationID = conversations.first(where: { conversation in
            conversation.kind == .group
                && (conversation.id == normalizedChannelID
                    || remoteChannelID(for: conversation) == normalizedChannelID)
        })?.id,
        let ticket = localMessageTicket,
        let context = mediaCacheScopeContext else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  context.sessionGeneration == self.localMessageSessionGeneration,
                  let candidates = try? await self.messagePersistence.removeMediaCacheReferences(
                    ticket: ticket,
                    conversationID: conversationID,
                    beforeChannelSequence: boundary.fromSeq,
                    clearAll: shouldClearForNewEpisode
                  ) else { return }
            for candidate in candidates {
                guard let url = self.mediaCacheURL(
                    relativePath: candidate.relativePath,
                    context: context
                ) else { continue }
                // JHT_MOD_BEGIN MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改开始：历史边界媒体缓存清理放到后台，避免阻塞聊天页交互
                await MediaCacheFileIO.removeFileIgnoringErrorsOffMain(url)
                // JHT_MOD_END MEDIA_CACHE_FILE_IO_PERF_20260912 - 修改结束
            }
        }
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, conversation: Conversation) -> Bool {
        guard conversation.kind == .group,
              let boundary = conversationStore.historyBoundary(for: conversation),
              boundary.isRestrictive else { return false }
        let code = DisasterRecoveryFallbackClassifier.normalizedCode(from: error)
        return code.contains("message_not_found")
            || code.contains("file_not_found")
            || code == "not_found"
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, conversationID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        return shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation)
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, messageID: String) -> Bool {
        conversations.contains { conversation in
            conversation.messages.contains { $0.id == messageID }
                && shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation)
        }
    }

    func shouldShowGroupHistoryLimitedMessage(for error: Error, file: FileItem) -> Bool {
        let channelID = file.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty,
              let conversation = conversations.first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) else { return false }
        return shouldShowGroupHistoryLimitedMessage(for: error, conversation: conversation)
    }

    @discardableResult
    func beginGroupHistoryBoundaryRequest(context: IMAPIContext, channelID: String, channelType: String) -> Int? {
        guard let key = groupHistoryBoundaryGenerationKey(context: context, channelID: channelID, channelType: channelType) else { return nil }
        return groupHistoryBoundaryGenerationTracker.begin(key: key)
    }

    func isCurrentGroupHistoryBoundaryResponse(context: IMAPIContext, channelID: String, channelType: String, generation: Int?) -> Bool {
        guard let generation,
              let key = groupHistoryBoundaryGenerationKey(context: context, channelID: channelID, channelType: channelType) else {
            return true
        }
        return groupHistoryBoundaryGenerationTracker.accepts(key: key, generation: generation)
    }

    private func groupHistoryBoundaryGenerationKey(context: IMAPIContext, channelID: String, channelType: String) -> String? {
        let normalizedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedChannelType == "group" else { return nil }
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenantID.isEmpty, !imUID.isEmpty, !normalizedChannelID.isEmpty else { return nil }
        return [tenantID, imUID, normalizedChannelID].joined(separator: "|")
    }

    /// 返回是否真正发起了旧消息加载请求。节流、窗口不可用、已到最早消息等
    /// 情况下返回 false,调用方据此决定是否关闭各自的重试门。
    @discardableResult
    func loadOlderMessagesIfAvailable(_ conversationID: String) -> Bool {
        guard apiContext.hasIMSession else {
            return loadOlderPersistedMessagesIfAvailable(conversationID)
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentRemoteRefresh(refreshSession, scope: scope) else {
            return loadOlderPersistedMessagesIfAvailable(conversationID)
        }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        guard !conversationStore.isHistoryLoading(conversationID: conversationID) else { return false }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        let availabilityPlan = conversationStore.olderHistoryAvailabilityPlan(for: conversation, historyKey: historyKey)
        guard case .available(let availabilityTarget) = availabilityPlan else {
            if case .reachedStart(_, let plannedConversationID) = availabilityPlan {
                conversationStore.setHistoryMessage(
                    conversationID: plannedConversationID,
                    message: historyLimitedReachedStartMessage(for: conversation)
                )
                return false
            }
            guard case .unavailable(_, let plannedConversationID) = availabilityPlan else { return false }
            // 窗口不可用是瞬态(常见于窗口里只有 channelSeq==0 的本地/系统消息),
            // 不再写入 historyReachedStartKeys 形成黏性死锁。若会话明确存在历史
            // (lastMsgSeq > 1),先强制同步一次最新窗口修复本地窗口,再走正常分页。
            if conversation.lastMsgSeq > 1, historyWindowRecoverySyncAttemptedKeys.insert(historyKey).inserted {
                syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: true,
                    trimToLatestWindow: true
                )
                return false
            }
            conversationStore.setHistoryMessage(
                conversationID: plannedConversationID,
                message: historyLimitedReachedStartMessage(for: conversation)
            )
            return false
        }
        let plannedHistoryKey = availabilityTarget.historyKey
        let plannedConversationID = availabilityTarget.conversationID
        let oldestSeq = availabilityTarget.oldestSeq
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let pageLimit = 50
        // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：旧分页去重索引延后到后台任务构建，避免进入历史加载时同步扫消息
        let existingMessagesSnapshot = conversation.messages
        // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
        guard conversationStore.beginOlderHistoryLoad(
            historyKey: plannedHistoryKey,
            conversationID: plannedConversationID,
            now: Date(),
            throttleInterval: conversationHistoryLoadThrottleInterval
        ) else {
            return false
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        Task {
            // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：旧分页去重索引后台构建
            async let existingWindowIndex = MessageHistoryPreparationBuilder.olderWindowIndexOffMain(
                messages: existingMessagesSnapshot,
                oldestSeq: oldestSeq
            )
            // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
            defer {
                conversationStore.finishOlderHistoryLoad(historyKey: plannedHistoryKey, conversationID: plannedConversationID)
            }
            do {
                if let ticket = localMessageTicket,
                   let persisted = try? await messagePersistence.loadOlderMessages(
                       ticket: ticket,
                       channelKey: channelID,
                       beforeSeq: oldestSeq,
                       limit: pageLimit
                   ),
                   isCurrentRemoteRefresh(refreshSession, scope: scope) {
                    // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：本地缓存消息恢复放到后台
                    let persistedModels = await MessageHistoryPreparationBuilder.cachedMessageModelsOffMain(persisted)
                    _ = conversationStore.mergePersistedMessagePage(
                        persistedModels,
                        conversationID: plannedConversationID
                    )
                    // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
                }
                let page = try await api.syncMessagesBefore(
                    context: context,
                    channelID: channelID,
                    channelType: channelType,
                    beforeSeq: oldestSeq,
                    limit: pageLimit
                )
                guard isCurrentRemoteRefresh(refreshSession, scope: scope),
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                let syncBoundary = historyBoundary(from: page, channelType: channelType)
                if let syncBoundary {
                    applyHistoryVisibilityBoundaryForGroup(
                        channelID: channelID,
                        boundary: syncBoundary
                    )
                }
                // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：使用后台构建的旧分页去重索引
                let windowIndex = await existingWindowIndex
                let olderMessages = page.items.filter { remote in
                    isRemoteMessageVisibleAfterHistoryBoundary(remote, boundary: syncBoundary)
                        &&
                    isRemoteMessageOlderThanCurrentWindow(
                        remote,
                        oldestSeq: oldestSeq,
                        existingIDs: windowIndex.existingIDs,
                        existingSeqs: windowIndex.existingSeqs
                    )
                }
                // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
                guard !olderMessages.isEmpty else {
                    let reachedHistoryBoundary = syncBoundary?.isRestrictive == true
                        || (page.hasMoreBefore == false && syncBoundary?.limited == true)
                    conversationStore.markOlderHistoryReachedStart(
                        historyKey: plannedHistoryKey,
                        conversationID: plannedConversationID,
                        message: reachedHistoryBoundary ? groupHistoryLimitedMessage : "已同步到最早消息"
                    )
                    await persistConversationSnapshotImmediately(
                        conversationID: plannedConversationID,
                        scope: scope,
                        source: .history
                    )
                    return
                }
                conversationStore.markOlderHistoryApplied(historyKey: plannedHistoryKey, conversationID: plannedConversationID)
                historyWindowRecoverySyncAttemptedKeys.remove(plannedHistoryKey)
                // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_REMOTE_PREPEND_CONTEXT - 修改开始：旧消息远端分页传入 beforeSeq，合并层可走保守增量路径
                applyRemoteMessages(
                    olderMessages,
                    channelID: channelID,
                    channelType: channelType,
                    historyBoundary: syncBoundary,
                    olderHistoryBeforeSeq: oldestSeq
                )
                // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_REMOTE_PREPEND_CONTEXT - 修改结束：旧消息远端分页传入 beforeSeq，合并层可走保守增量路径
                await persistConversationSnapshotImmediately(
                    conversationID: plannedConversationID,
                    scope: scope,
                    source: .history
                )
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            } catch {
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    conversationStore.setHistoryMessage(conversationID: plannedConversationID, message: "更早聊天记录同步失败，请稍后重试")
                    handleRemoteError(error, fallback: "聊天记录同步失败", silent: true)
                }
            }
        }
        return true
    }

    @discardableResult
    private func loadOlderPersistedMessagesIfAvailable(_ conversationID: String) -> Bool {
        guard !conversationStore.isHistoryLoading(conversationID: conversationID),
              let ticket = localMessageTicket,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        let oldestSeq = conversation.messages
            .map(\.channelSeq)
            .filter { $0 > 0 }
            .min() ?? 0
        guard oldestSeq > 0 else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        guard conversationStore.beginOlderHistoryLoad(
            historyKey: historyKey,
            conversationID: conversationID,
            now: Date(),
            throttleInterval: conversationHistoryLoadThrottleInterval
        ) else { return false }
        let channelID = remoteChannelID(for: conversation)
        Task {
            defer {
                conversationStore.finishOlderHistoryLoad(
                    historyKey: historyKey,
                    conversationID: conversationID
                )
            }
            guard let persisted = try? await messagePersistence.loadOlderMessages(
                ticket: ticket,
                channelKey: channelID,
                beforeSeq: oldestSeq,
                limit: 50
            ),
                  localMessageTicket?.scopeHash == ticket.scopeHash else { return }
            if persisted.isEmpty {
                conversationStore.setHistoryMessage(
                    conversationID: conversationID,
                    message: "本地已无更早记录，联网后继续同步"
                )
                return
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：离线本地分页消息恢复放到后台
            let persistedModels = await MessageHistoryPreparationBuilder.cachedMessageModelsOffMain(persisted)
            _ = conversationStore.mergePersistedMessagePage(
                persistedModels,
                conversationID: conversationID
            )
            // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
        }
        return true
    }

    func loadNewerMessagesIfAvailable(_ conversationID: String) {
        guard apiContext.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        guard !conversationStore.isHistoryLoading(conversationID: conversationID) else { return }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let historyKey = conversationHistoryStateKey(for: conversation)
        guard let target = conversationStore.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: historyKey,
            limit: latestConversationMessageWindowLimit
        ) else {
            return
        }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：新分页去重索引延后到后台任务构建
        let existingMessagesSnapshot = conversation.messages
        // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
        guard conversationStore.beginMessageSync(
            historyKey: target.historyKey,
            conversationID: target.conversationID,
            showLoadingIndicator: false
        ) else {
            return
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        Task {
            // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：新分页去重索引后台构建
            async let existingWindowIndex = MessageHistoryPreparationBuilder.newerWindowIndexOffMain(
                messages: existingMessagesSnapshot
            )
            // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
            defer {
                conversationStore.finishMessageSync(
                    historyKey: target.historyKey,
                    conversationID: target.conversationID,
                    showLoadingIndicator: false
                )
            }
            do {
                let page = try await api.syncMessages(
                    context: context,
                    channelID: channelID,
                    channelType: channelType,
                    afterSeq: target.afterSeq,
                    limit: target.limit
                )
                guard isCurrentRemoteRefresh(refreshSession, scope: scope),
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                let syncBoundary = historyBoundary(from: page, channelType: channelType)
                // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：使用后台构建的新分页去重索引
                let windowIndex = await existingWindowIndex
                let newerMessages = page.items.filter { remote in
                    isRemoteMessageVisibleAfterHistoryBoundary(remote, boundary: syncBoundary)
                        &&
                    isRemoteMessageNewerThanCurrentWindow(
                        remote,
                        newestSeq: target.afterSeq,
                        existingIDs: windowIndex.existingIDs,
                        existingSeqs: windowIndex.existingSeqs
                    )
                }
                // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
                guard !newerMessages.isEmpty else {
                    if let syncBoundary {
                        applyHistoryVisibilityBoundaryForGroup(
                            channelID: channelID,
                            boundary: syncBoundary
                        )
                    }
                    return
                }
                applyRemoteMessages(newerMessages, channelID: channelID, channelType: channelType, historyBoundary: syncBoundary)
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            } catch {
                guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    logSyncEndpointFailure("/api/im/sync", error: error, channelID: channelID, channelType: channelType)
                }
            }
        }
    }

    func hasOlderMessagesAvailable(_ conversationID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        return conversationStore.olderHistoryAvailabilityTarget(for: conversation, historyKey: historyKey) != nil
    }

    func hasNewerMessagesAvailable(_ conversationID: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        return conversationStore.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: historyKey,
            limit: latestConversationMessageWindowLimit
        ) != nil
    }

    func conversationHistoryStateKey(for conversation: Conversation) -> String {
        conversationStore.conversationHistoryKeyContext(
            tenantID: apiContext.tenantID,
            imUID: apiContext.imUID,
            conversationID: conversation.id
        ).historyKey
    }

    private func isRemoteMessageOlderThanCurrentWindow(_ remote: RemoteMessage, oldestSeq: Int64, existingIDs: Set<String>, existingSeqs: Set<Int64>) -> Bool {
        conversationStore.isRemoteMessageOlderThanCurrentWindow(
            remote,
            oldestSeq: oldestSeq,
            existingIDs: existingIDs,
            existingSeqs: existingSeqs
        )
    }

    private func isRemoteMessageNewerThanCurrentWindow(_ remote: RemoteMessage, newestSeq: Int64, existingIDs: Set<String>, existingSeqs: Set<Int64>) -> Bool {
        conversationStore.isRemoteMessageNewerThanCurrentWindow(
            remote,
            newestSeq: newestSeq,
            existingIDs: existingIDs,
            existingSeqs: existingSeqs
        )
    }

    func subscribeRealtimeConversation(_ conversationID: String) {
        flushPendingRealtimeMessagesIfNeeded(reason: "switch_conversation")
        _ = conversationSelectionEpochFence.select(
            scope: remoteDataScopeKey(for: apiContext),
            conversationID: conversationID
        )
        activeRealtimeConversationID = conversationID
        conversationStore.prepareActiveRealtimeConversationAutoRead(conversationID: conversationID)
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        startRealtimeConnection(context: apiContext)
        sendRealtimeSubscribe(for: conversation)
    }

    func updateRealtimeConversationAutoRead(_ conversationID: String, canAutoRead: Bool) {
        conversationStore.updateActiveRealtimeConversationAutoRead(
            conversationID: conversationID,
            activeConversationID: activeRealtimeConversationID,
            canAutoRead: canAutoRead
        )
    }

    func leaveRealtimeConversation(_ conversationID: String) {
        conversationSelectionEpochFence.leave(
            scope: remoteDataScopeKey(for: apiContext),
            conversationID: conversationID
        )
        if activeRealtimeConversationID == conversationID {
            activeRealtimeConversationID = nil
        }
        conversationStore.clearActiveRealtimeConversationAutoRead(conversationID: conversationID)
        cancelWarmConversationRefresh(conversationID)
    }

    func scheduleWarmConversationRefreshAfterInitialRender(_ conversationID: String) {
        guard apiContext.hasIMSession,
              conversations.contains(where: { $0.id == conversationID }) else { return }
        let refreshKey = warmConversationRefreshKey(conversationID)
        let expectedScope = activeConversationHistoryScope
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.conversationStore.finishWarmRefreshTask(refreshKey: refreshKey)
                guard self.activeConversationHistoryScope == expectedScope,
                      self.activeRealtimeConversationID == conversationID,
                      self.conversations.contains(where: { $0.id == conversationID }) else { return }
                self.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: false,
                    trimToLatestWindow: true
                )
            }
        }
        conversationStore.replaceWarmRefreshTask(refreshKey: refreshKey, task: task)
    }

    private func cancelWarmConversationRefresh(_ conversationID: String) {
        conversationStore.cancelWarmRefreshTasks(conversationID: conversationID)
    }

    private func warmConversationRefreshKey(_ conversationID: String) -> String {
        activeConversationScopedStateKeyContext(for: conversationID).stateKey
    }

}

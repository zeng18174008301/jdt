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
    func presenceStatusText(rawStatus: String, online: Bool?) -> String {
        Self.presenceStatusText(rawStatus: rawStatus, online: online, policy: resolvedTenantClientPolicy)
    }

    nonisolated static func presenceStatusText(
        rawStatus: String,
        online: Bool?,
        policy: RemoteTenantClientPolicy?
    ) -> String {
        ""
    }

    func scrubHiddenPresenceState() {
        let policy = resolvedTenantClientPolicy
        let hidesPresence = policy?.showOnlineStatus != true
        let hidesLastLogin = policy?.showLastLoginTime != true
        setCurrentUser(userWithPresenceStatus(
            currentUser,
            status: hidesPresence ? "" : currentUser.status,
            lastLoginAt: hidesLastLogin ? "" : currentUser.lastLoginAt
        )) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        contacts = contacts.map { user in
            userWithPresenceStatus(
                user,
                status: hidesPresence ? "" : user.status,
                lastLoginAt: hidesLastLogin ? "" : user.lastLoginAt
            )
        }
        groups = groups.map { group in
            var next = group
            next.members = group.members.map { user in
                userWithPresenceStatus(
                    user,
                    status: hidesPresence ? "" : user.status,
                    lastLoginAt: hidesLastLogin ? "" : user.lastLoginAt
                )
            }
            next.admins = group.admins.map { user in
                userWithPresenceStatus(
                    user,
                    status: hidesPresence ? "" : user.status,
                    lastLoginAt: hidesLastLogin ? "" : user.lastLoginAt
                )
            }
            return next
        }
        conversationStore.commitConversationSnapshots(conversationStore.conversationMessageSnapshots().map { conversation in
            var next = conversation
            next.participants = conversation.participants.map { user in
                userWithPresenceStatus(
                    user,
                    status: hidesPresence ? "" : user.status,
                    lastLoginAt: hidesLastLogin ? "" : user.lastLoginAt
                )
            }
            return next
        })
    }

    func userWithPresenceStatus(_ user: IMUser, status: String, lastLoginAt: String? = nil) -> IMUser {
        IMUser(
            id: user.id,
            userID: user.userID,
            username: user.username,
            name: user.name,
            title: user.title,
            department: user.department,
            departmentPathNames: user.departmentPathNames,
            phone: user.phone,
            phoneVerified: user.phoneVerified,
            realNameVerified: user.realNameVerified,
            realNameStatus: user.realNameStatus,
            email: user.email,
            status: status,
            lastLoginAt: lastLoginAt ?? user.lastLoginAt,
            enterprise: user.enterprise,
            avatarSeed: user.avatarSeed,
            avatarURL: user.avatarURL,
            avatarVersion: user.avatarVersion,
            avatarUpdatedAt: user.avatarUpdatedAt,
            badges: user.badges
        )
    }

    func preferredDisplayName(candidates: [String?], identifiers: [String?] = [], fallback: String) -> String {
        let normalizedIdentifiers = identifiers
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedCandidates = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let usable = normalizedCandidates.first(where: { candidate in
            guard !isIdentifierLikeDisplayName(candidate, matching: "") else { return false }
            return !normalizedIdentifiers.contains { id in
                isIdentifierLikeDisplayName(candidate, matching: id)
            }
        }) {
            return usable
        }
        return normalizedCandidates.first ?? fallback
    }

    // JHT_MOD_BEGIN APPSTATE_REMOTE_CONVERSATION_TIME_DECOUPLE_PERF_20260913 - 修改开始：远端会话时间/排序委托给 Core/AppSupport 纯计算 helper
    private func remoteConversationActivityDate(_ remote: RemoteConversation, previous: ConversationMessageSnapshot?) -> Date? {
        RemoteConversationTimelineMapper.activityDate(remote: remote, previous: previous)
    }

    private func remoteConversationTime(_ remote: RemoteConversation, previous: ConversationMessageSnapshot?, activityDate: Date?) -> String {
        RemoteConversationTimelineMapper.displayTime(remote: remote, previous: previous, activityDate: activityDate)
    }

    func remoteConversationSortTimestamp(_ remote: RemoteConversation, previous: ConversationMessageSnapshot? = nil) -> TimeInterval {
        RemoteConversationTimelineMapper.sortTimestamp(remote: remote, previous: previous)
    }

    func remoteConversationLatestSeq(_ remote: RemoteConversation) -> Int64 {
        RemoteConversationTimelineMapper.latestSeq(remote: remote)
    }

    private func remoteConversationFreshnessPrecedes(_ lhs: RemoteConversation, _ rhs: RemoteConversation) -> Bool {
        RemoteConversationTimelineMapper.freshnessPrecedes(lhs, rhs)
    }
    // JHT_MOD_END APPSTATE_REMOTE_CONVERSATION_TIME_DECOUPLE_PERF_20260913 - 修改结束

    func canonicalRemoteConversations(_ remoteConversations: [RemoteConversation], lookup: ConversationUserLookup? = nil) -> [RemoteConversation] {
        // JHT_MOD_BEGIN APPSTATE_REMOTE_CONVERSATION_CANONICALIZER_PERF_20260913 - 修改开始：一次性生成身份 lookup 快照，去重选择委托给纯 helper
        let currentID = (apiContext.imUID?.isEmpty == false ? apiContext.imUID : currentUser.id) ?? currentUser.id
        let effectiveLookup: ConversationUserLookup?
        if let lookup {
            effectiveLookup = lookup
        } else if remoteConversations.contains(where: { remote in
            conversationKind(from: remote.channelType, channelID: remote.channelID) == .direct
        }) {
            effectiveLookup = makeConversationUserLookup()
        } else {
            effectiveLookup = nil
        }
        return RemoteConversationCanonicalizer.canonical(
            remoteConversations,
            currentID: currentID,
            currentIDs: currentUserIdentitySet(),
            lookup: effectiveLookup
        )
        // JHT_MOD_END APPSTATE_REMOTE_CONVERSATION_CANONICALIZER_PERF_20260913 - 修改结束
    }

    func resolvedConversationMemberCount(
        kind: ConversationKind,
        channelID: String,
        previous: ConversationMessageSnapshot?,
        participants: [IMUser],
        reportedCount: Int? = nil
    ) -> Int? {
        guard kind == .group else { return participants.count }
        guard shouldShowGroupMemberCount else { return nil }
        let directoryCount = groups.first(where: { $0.id == channelID || $0.id == previous?.id })?.memberCount
        return reportedCount.flatMap { $0 >= 0 ? $0 : nil } ?? directoryCount ?? previous?.memberCount
    }

    func applyRemoteConversations(_ remoteConversations: [RemoteConversation], replacing: Bool) {
        return conversationStore.performMemoryCommand { // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
            let scope = remoteDataScopeKey(for: apiContext)
            let lookup = makeConversationUserLookup()
            let visibleRemoteConversations = visibleRemoteConversationsAfterLocalHiding(
                remoteConversations,
                scope: scope,
                lookup: lookup
            )
            let canonicalRemotes = canonicalRemoteConversations(visibleRemoteConversations, lookup: lookup)
            guard !canonicalRemotes.isEmpty else {
                conversationStore.mergeRemoteConversationList(
                    entries: [],
                    replacing: replacing,
                    channelIDForConversation: { remoteChannelID(for: $0, lookup: lookup) }
                )
                // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：无远端会话时隐藏收敛仅在变化后发布
                conversationStore.replaceConversationsIfChanged(
                    visibleConversationsAfterLocalHiding(
                        conversationStore.conversationMessageSnapshots(),
                        scope: scope,
                        lookup: lookup
                    ),
                    reason: "remote_conversations_empty_visibility"
                )
                // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束
                reapplyAllAvatarRealtimeProjections()
                return
            }
            let previousByChannelID = conversationStore.conversationsByChannelID(channelIDForConversation: { remoteChannelID(for: $0, lookup: lookup) })
            var mergeEntries: [ConversationStore.RemoteConversationMergeEntry] = []
            for remote in canonicalRemotes {
                let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType, lookup: lookup)
                let kind = conversationKind(from: remote.channelType, channelID: channelID)
                let historyBoundary = self.historyBoundary(from: remote, kind: kind)
                if let historyBoundary {
                    pruneDerivedCachesForHistoryBoundary(channelID: channelID, boundary: historyBoundary)
                }
                let previous = conversationStore.applyingHistoryVisibilityBoundary(
                    historyBoundary,
                    to: previousByChannelID[channelID]
                ) ?? previousByChannelID[channelID]
                let boundedLastMessage = remote.lastMessage.flatMap { message in
                    isRemoteMessageVisibleAfterHistoryBoundary(message, boundary: historyBoundary) ? message : nil
                }
                let title = conversationTitle(channelID: channelID, kind: kind, previous: previous, remoteDisplayName: remote.displayName, lookup: lookup)
                let participants = conversationParticipants(channelID: channelID, kind: kind, previous: previous, lookup: lookup)
                let memberCount = resolvedConversationMemberCount(
                    kind: kind,
                    channelID: channelID,
                    previous: previous,
                    participants: participants,
                    reportedCount: remote.memberCount
                )
                let matchedGroup = kind == .group ? groups.first(where: { $0.id == channelID }) : nil
                let remoteGroupAvatarPath = kind == .group && remote.avatarProvided
                    ? authoritativeGroupAvatarPath(remote.avatar)
                    : ""
                let groupAvatarURL: String
                let groupAvatarVersion: String
                let groupAvatarUpdatedAt: String
                if let matchedGroup {
                    groupAvatarURL = matchedGroup.avatarURL
                    groupAvatarVersion = matchedGroup.avatarVersion
                    groupAvatarUpdatedAt = matchedGroup.avatarUpdatedAt
                } else if kind == .group, remote.avatarProvided {
                    groupAvatarURL = isDefaultGroupAvatarURL(remoteGroupAvatarPath) ? "" : remoteGroupAvatarPath
                    groupAvatarVersion = groupAvatarURL.isEmpty ? "" : remote.avatarVersion
                    groupAvatarUpdatedAt = groupAvatarURL.isEmpty ? "" : remote.avatarUpdatedAt
                } else {
                    groupAvatarURL = previous?.avatarURL ?? ""
                    groupAvatarVersion = previous?.avatarVersion ?? ""
                    groupAvatarUpdatedAt = previous?.avatarUpdatedAt ?? ""
                }
                let normalizedChannelType = normalizedReadWatermarkChannelType(channelID: channelID, channelType: remote.channelType)
                let readStateKey = conversationReadStateKey(channelID: channelID, channelType: normalizedChannelType, lookup: lookup)
                let readWatermarkScope = currentReadWatermarkScope(channelID: channelID, channelType: normalizedChannelType, lookup: lookup)
                let exactReadSeq = conversationStore.effectiveReadSeq(readStateKey: readStateKey, scope: readWatermarkScope)
                let legacyReadSeq = readWatermarkScope == nil ? locallyReadSeq(for: remote) : 0
                let localReadSeq = max(previous?.lastReadSeq ?? 0, legacyReadSeq, exactReadSeq)
                let lastReadSeq = max(localReadSeq, remote.lastReadSeq)
                let latestSeq = remoteConversationLatestSeq(remote)
                let previousTail = previous?.lastMsgSeq ?? 0
                let knownTail = max(latestSeq, previousTail)
                let staleUnreadProjection = localReadSeq > remote.lastReadSeq
                let usesPreviousUnread = previous != nil
                    && (latestSeq < previousTail || (staleUnreadProjection && latestSeq == previousTail))
                let locallyReadThrough: Bool
                if knownTail > 0 {
                    locallyReadThrough = lastReadSeq >= knownTail
                } else {
                    locallyReadThrough = readWatermarkScope == nil && isConversationLocallyReadThrough(remote)
                }
                let rawUnreadState = resolvedConversationUnreadState(
                    remoteUnreadCount: boundedConversationMessageUnreadCount(
                        usesPreviousUnread ? previous?.unread ?? 0 : remote.unreadCount,
                        lastMsgSeq: knownTail,
                        lastReadSeq: lastReadSeq
                    ),
                    remoteUnreadReactionCount: staleUnreadProjection ? previous?.unreadReactionCount ?? 0 : remote.unreadReactionCount,
                    remoteHasReactionUnread: staleUnreadProjection ? previous?.hasUnreadReaction == true : remote.hasReactionUnread,
                    locallyReadThrough: locallyReadThrough
                )
                let unreadState: ConversationUnreadState
                if let historyBoundary,
                   historyBoundary.isRestrictive,
                   remote.firstUnreadSeq > 0,
                   remote.firstUnreadSeq < historyBoundary.fromSeq {
                    unreadState = ConversationUnreadState(
                        unreadCount: 0,
                        hasUnreadReaction: false,
                        unreadReactionCount: 0,
                        hasUnreadMessages: false
                    )
                } else {
                    unreadState = rawUnreadState
                }
                let suppressRemoteActivity = historyBoundary?.isRestrictive == true
                    && remote.lastMessage != nil
                    && boundedLastMessage == nil
                let activityDate: Date?
                if suppressRemoteActivity {
                    if let previousSortTimestamp = previous?.sortTimestamp, previousSortTimestamp > 0 {
                        activityDate = Date(timeIntervalSince1970: previousSortTimestamp)
                    } else {
                        activityDate = nil
                    }
                } else {
                    activityDate = remoteConversationActivityDate(remote, previous: previous)
                }
                let sortTimestamp = activityDate?.timeIntervalSince1970 ?? previous?.sortTimestamp ?? 0
                let time = suppressRemoteActivity
                    ? previous?.time ?? ""
                    : remoteConversationTime(remote, previous: previous, activityDate: activityDate)
                let mappedBoundedLastMessage = boundedLastMessage.map {
                    chatMessage(from: $0, participants: participants)
                }
                var mappedMessages = previous?.messages ?? mappedBoundedLastMessage.map { [$0] } ?? []
                var rtcListConflictSeq: Int64?
                if previous != nil,
                   let mappedBoundedLastMessage,
                   mappedBoundedLastMessage.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" {
                    switch RTCCallRecordMessageDeduplicator.listSummaryMergeDecision(
                        existingMessages: mappedMessages,
                        candidate: mappedBoundedLastMessage
                    ) {
                    case .append:
                        mappedMessages.append(mappedBoundedLastMessage)
                    case .exactDuplicate:
                        break
                    case let .conflict(sequence):
                        rtcListConflictSeq = sequence
                    }
                }
                let mappedCoverage = rtcListConflictSeq.map { conflictSeq in
                    min(previous?.messageCoveredThroughSeq ?? 0, max(0, conflictSeq - 1))
                } ?? previous?.messageCoveredThroughSeq ?? 0
                let localTail = previous?.messages.last(where: { !$0.isPinnedContextOnly })
                let keepLocalSummary = rtcListConflictSeq != nil
                    || (localTail?.isDeletedLocally == true && localTail?.id == boundedLastMessage?.messageID)
                // The list response may be newer than the history loaded for this row.
                let mappedLastMessagePreview = keepLocalSummary
                    ? previous?.lastMessage ?? ""
                    : mappedBoundedLastMessage?.conversationAttachmentPreview
                        ?? boundedLastMessage.map { messagePreview($0, participants: participants) }
                        ?? previous?.lastMessage ?? ""
                let mentionSummary = remote.mentionSummary
                let attachmentMentionPreview: String? = {
                    guard let mentionSummary, let latest = mappedBoundedLastMessage,
                          (!mentionSummary.messageID.isEmpty && mentionSummary.messageID == latest.id)
                            || (mentionSummary.channelSeq > 0 && mentionSummary.channelSeq == latest.channelSeq) else { return nil }
                    return latest.conversationAttachmentPreview
                }()
                let mappedTime = keepLocalSummary ? previous?.time ?? "" : time
                let mappedSortTimestamp = keepLocalSummary ? previous?.sortTimestamp ?? 0 : sortTimestamp
                var mapped = ConversationMessageSnapshot(
                    id: kind == .system ? "system_notification" : (previous?.id ?? channelID),
                    title: title,
                    subtitle: kind.rawValue,
                    kind: kind,
                    lastMessage: mappedLastMessagePreview,
                        time: mappedTime,
                        unread: unreadState.unreadCount,
                        isPinned: remote.stick,
                        isMuted: remote.muteProvided ? remote.mute : previous?.isMuted ?? false,
                        memberCount: memberCount,
                    accentHex: previous?.accentHex ?? stableSeed(channelID),
                    participants: participants,
                    messages: mappedMessages,
                    avatarURL: groupAvatarURL,
                    avatarVersion: groupAvatarVersion,
                    avatarUpdatedAt: groupAvatarUpdatedAt,
                    hasUnreadReaction: unreadState.hasUnreadReaction,
                    unreadReactionCount: unreadState.unreadReactionCount,
                    lastMsgSeq: max(previous?.lastMsgSeq ?? 0, remote.lastMsgSeq, boundedLastMessage?.channelSeq ?? 0),
                    messageCoveredThroughSeq: mappedCoverage,
                    messageCoverageRequiresRecovery: previous?.messageCoverageRequiresRecovery == true || rtcListConflictSeq != nil,
                    lastReadSeq: lastReadSeq,
                    firstUnreadSeq: unreadState.hasUnreadMessages ? remote.firstUnreadSeq : 0,
                    firstUnreadMessageID: unreadState.hasUnreadMessages ? remote.firstUnreadMessageID : "",
                    unreadAnchorSeq: unreadState.hasUnreadMessages ? remote.unreadAnchorSeq : 0,
                    unreadAnchorState: unreadState.hasUnreadMessages ? remote.unreadAnchorState : "none",
                    hasMention: unreadState.hasUnreadMessages && remote.hasMention,
                    mentionCount: unreadState.hasUnreadMessages ? remote.mentionCount : 0,
                    mentionSummaryText: unreadState.hasUnreadMessages ? (attachmentMentionPreview ?? mentionSummary?.text ?? "") : "",
                    mentionSummaryMessageID: unreadState.hasUnreadMessages ? (remote.mentionSummary?.messageID ?? "") : "",
                    mentionSummaryChannelSeq: unreadState.hasUnreadMessages ? (remote.mentionSummary?.channelSeq ?? 0) : 0,
                    sortTimestamp: mappedSortTimestamp,
                    historyVisibleFromSeq: historyBoundary?.fromSeq ?? previous?.historyVisibleFromSeq ?? 1,
                    historyLimited: historyBoundary?.limited ?? previous?.historyLimited ?? false,
                    historyBoundaryConfirmed: historyBoundary?.confirmed ?? previous?.historyBoundaryConfirmed ?? false
                )
                if let lastMessage = boundedLastMessage {
                    applyRemoteReadSummary(from: lastMessage, toMessagesIn: &mapped)
                }
                if remote.pinnedMessagesProvided {
                    let entries = pinnedMessageSnapshotEntries(
                        from: remote.pinnedMessages,
                        participants: participants
                    )
                    mapped = conversationStore.applyingPinnedMessageSnapshot(entries, to: mapped)
                }
                mergeEntries.append(ConversationStore.RemoteConversationMergeEntry(
                    channelID: channelID,
                    remote: remote,
                    conversation: mapped
                ))
            }
            let mergeResult = conversationStore.mergeRemoteConversationList(
                entries: mergeEntries,
                replacing: replacing,
                channelIDForConversation: { remoteChannelID(for: $0, lookup: lookup) }
            )
            let shouldPlayIncomingMessageSound = mergeResult.soundCandidates.contains { candidate in
                shouldPlayMessageSound(previous: candidate.previous, remote: candidate.remote, mapped: candidate.mapped)
            }
            let remoteIncludesSystemConversation = canonicalRemotes.contains { remote in
                let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType, lookup: lookup)
                return conversationKind(from: remote.channelType, channelID: channelID) == .system
            }
            if !inboxItems.isEmpty && !remoteIncludesSystemConversation {
                syncSystemConversationFromInbox(inboxItems)
            }
            pruneNonFriendDirectConversations()
            // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：远端会话合并后隐藏收敛仅在变化后发布，减少无变化列表重绘
            conversationStore.replaceConversationsIfChanged(
                visibleConversationsAfterLocalHiding(
                    conversationStore.conversationMessageSnapshots(),
                    scope: scope,
                    lookup: lookup
                ),
                reason: "remote_conversations_visibility"
            )
            // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束
            if shouldPlayIncomingMessageSound {
                SystemNotificationSound.playMessage()
            }
            if !shouldShowGroupMemberCount {
                conversationStore.scrubGroupMemberTotals()
            }
            reapplyAllAvatarRealtimeProjections()
        } // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
    }

    func pinnedMessageSnapshotEntries(from remotes: [RemoteMessage], participants: [IMUser]) -> [ConversationStore.PinnedMessageSnapshotEntry] {
        remotes.map { remote in
            var message = chatMessage(from: remote, participants: participants)
            message.isPinned = true
            message.isPinnedContextOnly = true
            return ConversationStore.PinnedMessageSnapshotEntry(
                messageID: remote.messageID,
                status: remote.status,
                message: message
            )
        }
    }

    private func shouldPlayMessageSound(previous: ConversationMessageSnapshot?, remote: RemoteConversation, mapped: ConversationMessageSnapshot) -> Bool {
        guard isAuthenticated,
              !isAuthLoading,
              !isRestoringSession,
              let previous,
              !previous.messages.isEmpty,
              !mapped.isMuted,
              remote.unreadCount > previous.unread,
              let lastMessage = remote.lastMessage,
              !isRemoteMessageFromCurrentUser(lastMessage),
              !previous.messages.contains(where: { $0.id == lastMessage.messageID }) else {
            return false
        }
        if lastMessage.channelSeq > 0, lastMessage.channelSeq <= mapped.lastReadSeq {
            return false
        }
        if lastMessage.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" {
            guard mapped.messages.contains(where: { message in
                message.id == lastMessage.messageID && message.rtcCallRecord != nil
            }) else { return false }
        }
        return true
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

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
    func updateGroupDetail(_ groupID: String, from detail: RemoteGroupDetail) async {
        let existing = group(id: groupID)
        let mapped = groupInfo(from: detail.summary, detail: detail, existing: existing)
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index] = mapped
        } else {
            groups.append(mapped)
        }
        ensureGroupConversationExists(mapped)
        applyGroupHistoryBoundary(mapped)
        scheduleGroupMuteBoundaryRefresh(for: mapped, context: apiContext)
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: remoteDataScopeKey(for: apiContext))
        }
        reapplyAllAvatarRealtimeProjections()
        scheduleRemoteSnapshotCacheWrite(scope: remoteDataScopeKey(for: apiContext))
    }

    func updateGroupSummary(
        _ groupID: String,
        from summary: RemoteGroupSummary,
        profileGenerationAtRequestStart: Int64,
        announcementPrivacyEpochAtRequestStart: UInt64
    ) async {
        let existing = group(id: groupID)
        let mapped = groupInfo(from: summary.summary, summary: summary, existing: existing)
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index] = mapped
        } else {
            groups.append(mapped)
        }
        ensureGroupConversationExists(mapped)
        applyGroupHistoryBoundary(mapped)
        scheduleGroupMuteBoundaryRefresh(for: mapped, context: apiContext)
        if let currentAnnouncement = summary.currentAnnouncement {
            let mappedAnnouncement = groupAnnouncement(
                from: currentAnnouncement,
                fallbackGroupID: groupID,
                requestPrivacyEpoch: announcementPrivacyEpochAtRequestStart
            )
            let existingAnnouncement = groupAnnouncements[groupID]?.first(where: { $0.id == mappedAnnouncement.id })
                ?? currentGroupAnnouncements[groupID]
            let acceptedAnnouncement = existingAnnouncement.map {
                preferredGroupAnnouncement(existing: $0, incoming: mappedAnnouncement)
            } ?? mappedAnnouncement
            upsertGroupAnnouncement(acceptedAnnouncement, markCurrentRead: !acceptedAnnouncement.unread)
        }
        if !summary.memberPreview.isEmpty {
            applyGroupMembers(
                summary.memberPreview,
                total: summary.memberCount,
                groupID: groupID,
                partial: !summary.isMemberPreviewComplete,
                nextOffset: summary.isMemberPreviewComplete ? nil : summary.memberPreview.count,
                profileGenerationAtRequestStart: profileGenerationAtRequestStart
            )
        }
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: remoteDataScopeKey(for: apiContext))
        }
        reapplyAllAvatarRealtimeProjections()
        scheduleRemoteSnapshotCacheWrite(scope: remoteDataScopeKey(for: apiContext))
    }

    func groupSummaryWithLegacyFallback(context: IMAPIContext, groupID: String) async throws -> RemoteGroupSummary {
        do {
            return try await api.groupSummary(context: context, groupID: groupID)
        } catch IMAPIError.httpStatus(let statusCode, _) where statusCode == 404 || statusCode == 405 {
            let detail = try await api.groupDetail(context: context, groupID: groupID)
            let preview = ([detail.owner].compactMap { $0 } + detail.admins).reduce(into: [RemoteUserGroupMember]()) { partial, member in
                let key = member.imUID.isEmpty ? member.userID : member.imUID
                if !partial.contains(where: { ($0.imUID.isEmpty ? $0.userID : $0.imUID) == key }) {
                    partial.append(member)
                }
            }
            return RemoteGroupSummary(
                summary: detail.summary,
                myRole: detail.myRole,
                memberCount: detail.memberCount,
                owner: detail.owner,
                memberPreview: preview,
                counts: RemoteGroupSummaryCounts(
                    memberCount: detail.memberCount,
                    adminCount: nil,
                    pendingJoinRequestCount: detail.settings.pendingJoinRequestCount,
                    fileCount: detail.settings.fileCount
                ),
                currentAnnouncement: detail.currentAnnouncement,
                settings: detail.settings,
                explicitMyRole: detail.explicitMyRole,
                memberFriendApplyEnabled: detail.memberFriendApplyEnabled
            )
        }
    }

    func searchGroupMentionMembers(groupID: String, keyword: String) async -> [IMUser] {
        let context = apiContext
        guard context.hasIMSession else { return [] }
        let scope = remoteDataScopeKey(for: context)
        let trimmedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGroupID.isEmpty else { return [] }
        let profileKey = groupMemberProfileCacheKey(groupID: trimmedGroupID, context: context)
        let profileGenerationAtRequestStart = groupMemberProfileGenerationFloor(groupID: trimmedGroupID)
        let refreshEpoch = groupMemberProfileRefreshEpoch
        let groupRefreshEpoch = groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
        guard isCurrentGroupMemberProfileRefresh(
            scope: scope,
            key: profileKey,
            globalEpoch: refreshEpoch,
            groupEpoch: groupRefreshEpoch
        ) else { return [] }
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let localMatches = localMentionMemberMatches(groupID: trimmedGroupID, keyword: trimmedKeyword)
        do {
            let members = try await api.listGroupMembersPaged(
                context: context,
                groupID: trimmedGroupID,
                limit: trimmedKeyword.isEmpty ? 100 : 60,
                offset: nil,
                cursor: nil,
                keyword: trimmedKeyword.isEmpty ? nil : trimmedKeyword,
                role: nil
            )
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return [] }
            let remoteMatches = members.items.map { groupMemberUser(from: $0) }
            guard !trimmedKeyword.isEmpty else {
                let hasMore = members.hasMore == true || (members.total ?? 0) > members.items.count
                applyGroupMembers(
                    members.items,
                    selfMember: members.selfMember,
                    total: members.total,
                    groupID: trimmedGroupID,
                    partial: hasMore,
                    nextOffset: hasMore ? members.nextOffset : nil,
                    nextCursor: hasMore ? members.nextCursor : nil,
                    profileGenerationAtRequestStart: profileGenerationAtRequestStart
                )
                return deduplicatedMentionSearchUsers(remoteMatches + localMatches)
            }
            let locallyRanked = IMUserSearchMatcher.sortedMatches(users: remoteMatches + localMatches, query: trimmedKeyword)
            return deduplicatedMentionSearchUsers(locallyRanked + remoteMatches + localMatches)
        } catch {
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return [] }
            return localMatches
        }
    }

    private func localMentionMemberMatches(groupID: String, keyword: String) -> [IMUser] {
        let group = groups.first { $0.id == groupID }
        let fallbackConversation = conversationStore.conversationMessageSnapshots().first { conversation in
            conversation.kind == .group && (conversation.id == groupID || remoteChannelID(for: conversation) == groupID)
        }
        let members = group?.members.isEmpty == false
            ? (group?.members ?? [])
            : (fallbackConversation?.participants ?? [])
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return deduplicatedMentionSearchUsers(members)
        }
        return deduplicatedMentionSearchUsers(IMUserSearchMatcher.sortedMatches(users: members, query: keyword))
    }

    private func deduplicatedMentionSearchUsers(_ users: [IMUser]) -> [IMUser] {
        var seen = Set<String>()
        return users.filter { user in
            let key = [
                user.id,
                user.userID,
                user.username
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    func applyGroupMembers(
        _ members: [RemoteUserGroupMember],
        selfMember: RemoteUserGroupMember? = nil,
        total: Int?,
        groupID: String,
        partial: Bool = false,
        nextOffset: Int? = nil,
        nextCursor: String? = nil,
        append: Bool = false,
        profileGenerationAtRequestStart: Int64? = nil
    ) {
        let profileKey = groupMemberProfileCacheKey(groupID: groupID)
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let responseGeneration = (members + [selfMember].compactMap { $0 })
            .map { max($0.groupMembershipGeneration, $0.revision) }
            .max() ?? 0
        let currentGenerationFloor = groupMemberProfileGenerationFloor(groupID: groupID)
        if let profileGenerationAtRequestStart,
           currentGenerationFloor != profileGenerationAtRequestStart {
            return
        }
        if responseGeneration > 0 {
            guard shouldAcceptGroupMemberProfileGeneration(responseGeneration, key: profileKey) else {
                return
            }
            recordAcceptedGroupMemberProfileGeneration(responseGeneration, key: profileKey)
        } else if currentGenerationFloor > 0 && profileGenerationAtRequestStart == nil {
            // An unversioned result is safe only when it was requested after
            // the current positive fence and that fence stayed unchanged.
            return
        }
        let effectiveResponseGeneration = responseGeneration > 0
            ? responseGeneration
            : (profileGenerationAtRequestStart ?? 0)
        let existingMembers = groups.first(where: { $0.id == groupID })?.members ?? []
        let users = members.map { member in
            groupMemberUser(from: member, fallback: fallbackUser(for: member, existingMembers: existingMembers))
        }
        let admins = members.filter { $0.isAdmin || $0.role == "admin" || $0.role == "owner" }.map { member in
            groupMemberUser(from: member, fallback: fallbackUser(for: member, existingMembers: existingMembers))
        }
        let currentIdentityValues = currentUserIdentitySet()
        if let remoteSelf = [selfMember].compactMap({ $0 }).first(where: {
               currentIdentityValues.contains($0.imUID) || currentIdentityValues.contains($0.userID) || currentIdentityValues.contains($0.accountID)
           }) ?? members.first(where: {
               currentIdentityValues.contains($0.imUID) || currentIdentityValues.contains($0.userID) || currentIdentityValues.contains($0.accountID)
           }) {
            // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_BEGIN
            cacheMyGroupSelfProfile(
                nickname: remoteSelf.groupNickname,
                key: profileKey,
                generation: max(
                    effectiveResponseGeneration,
                    max(remoteSelf.groupMembershipGeneration, remoteSelf.revision)
                ),
                member: groupMemberUser(from: remoteSelf, fallback: currentUser)
            )
            // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110_END
            applyCurrentUser(member: remoteSelf)
            let normalizedRole = remoteSelf.isOwner || remoteSelf.role == "owner"
                ? "owner"
                : (remoteSelf.isAdmin || remoteSelf.role == "admin" ? "admin" : "member")
            groups[index].myRole = normalizedRole
            groups[index].canManageMuteList = normalizedRole == "owner" || normalizedRole == "admin"
        }
        let existingGroup = groups[index]
        let refreshedIDs = Set(users.map(\.id))
        let preservedAdmins = existingGroup.admins.filter { !refreshedIDs.contains($0.id) }
        let mergedUsers = append ? mergingGroupUsers(existing: existingMembers, incoming: users) : users
        let mergedAdmins = append ? deduplicatedGroupUsers(admins + preservedAdmins) : admins
        let loadedCount = max(mergedUsers.count, append ? existingGroup.membersLoadedCount + users.count : users.count)
        let resolvedTotal = total ?? existingGroup.memberCount
        let reachedExplicitTotal = resolvedTotal.map { $0 > 0 && mergedUsers.count >= $0 } == true
        let resolvedPartial = partial && !reachedExplicitTotal
        let existingLooksComplete = !existingGroup.membersPartial
            && !existingMembers.isEmpty
            && (resolvedTotal.map { $0 <= 0 || existingMembers.count >= $0 } ?? false
                || existingMembers.count >= users.count)
        let shouldReplaceMembers = !users.isEmpty
            && (!partial || append || existingMembers.isEmpty || existingGroup.membersPartial || !existingLooksComplete)
        if shouldReplaceMembers {
            groups[index].members = mergedUsers
            groups[index].admins = mergedAdmins
            groups[index].membersPartial = resolvedPartial
            groups[index].membersLoadedCount = loadedCount
            groups[index].membersNextOffset = resolvedPartial ? nextOffset : nil
            groups[index].membersNextCursor = resolvedPartial ? nextCursor : nil
        } else if !users.isEmpty {
            // A partial refresh preserves the complete roster, but it must
            // still replace the returned members' nickname/role projections.
            groups[index].members = mergingGroupUsers(existing: existingMembers, incoming: users)
            groups[index].admins = deduplicatedGroupUsers(admins + preservedAdmins)
            groups[index].membersLoadedCount = max(existingGroup.membersLoadedCount, existingMembers.count)
            if !existingGroup.membersPartial {
                groups[index].membersNextOffset = nil
                groups[index].membersNextCursor = nil
            }
        } else if !partial {
            groups[index].membersPartial = false
            groups[index].membersLoadedCount = existingMembers.count
            groups[index].membersNextOffset = nil
            groups[index].membersNextCursor = nil
        }
        if shouldShowGroupMemberCount, let total, total > 0 {
            groups[index].memberCount = total
        } else if !shouldShowGroupMemberCount {
            groups[index].memberCount = nil
        }
        if let owner = members.first(where: { $0.isOwner || $0.role == "owner" }) {
            let ownerUser = groupMemberUser(
                from: owner,
                fallback: fallbackUser(for: owner, existingMembers: existingMembers)
            )
            groups[index].ownerID = owner.imUID.isEmpty ? owner.userID : owner.imUID
            groups[index] = GroupInfo(
                id: groups[index].id,
                name: groups[index].name,
                groupRevision: groups[index].groupRevision,
                avatarURL: groups[index].avatarURL,
                avatarVersion: groups[index].avatarVersion,
                avatarUpdatedAt: groups[index].avatarUpdatedAt,
                notice: groups[index].notice,
                groupDescription: groups[index].groupDescription,
                owner: ownerUser.name.isEmpty ? groups[index].owner : ownerUser.name,
                ownerID: groups[index].ownerID,
                members: groups[index].members,
                admins: groups[index].admins,
                membersPartial: groups[index].membersPartial,
                membersLoadedCount: groups[index].membersLoadedCount,
                membersNextOffset: groups[index].membersNextOffset,
                membersNextCursor: groups[index].membersNextCursor,
                muted: groups[index].muted,
                allMuted: groups[index].allMuted,
                allMuteStart: groups[index].allMuteStart,
                allMuteEnd: groups[index].allMuteEnd,
                allMuteMode: groups[index].allMuteMode,
                allMuteActive: groups[index].allMuteActive,
                allMuteServerTime: groups[index].allMuteServerTime,
                allMuteNextBoundary: groups[index].allMuteNextBoundary,
                allMuteRepairRequired: groups[index].allMuteRepairRequired,
                allMuteUpdatedAt: groups[index].allMuteUpdatedAt,
                myRole: groups[index].myRole,
                memberCount: groups[index].memberCount,
                adminCount: groups[index].adminCount,
                memberFriendApplyEnabled: groups[index].memberFriendApplyEnabled,
                memberPreview: groups[index].memberPreview,
                presentedRole: groups[index].presentedRole,
	                inviteConfirmRequired: groups[index].inviteConfirmRequired,
	                pendingJoinRequestCount: groups[index].pendingJoinRequestCount,
	                fileCount: groups[index].fileCount,
                blacklistCount: groups[index].blacklistCount,
                historyVisible: groups[index].historyVisible,
                historyVisibleFromSeq: groups[index].historyVisibleFromSeq,
                historyLimited: groups[index].historyLimited,
                groupMuted: groups[index].groupMuted,
                canManageMuteList: groups[index].canManageMuteList,
                muteListCount: groups[index].muteListCount
	            )
	        }
        conversationStore.setGroupConversationParticipants(
            groupID: groupID,
            groupName: groups[index].name,
            participants: groups[index].members,
            memberCount: shouldShowGroupMemberCount ? groups[index].memberCount : nil
        )
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: remoteDataScopeKey(for: apiContext))
        }
        reapplyAllAvatarRealtimeProjections()
    }

    private func deduplicatedGroupUsers(_ users: [IMUser]) -> [IMUser] {
        var seen = Set<String>()
        return users.filter { user in
            let key = [user.id, user.userID, user.username]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            guard !key.isEmpty else { return true }
            return seen.insert(key).inserted
        }
    }

    private func mergingGroupUsers(existing: [IMUser], incoming: [IMUser]) -> [IMUser] {
        let replacements = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return deduplicatedGroupUsers(existing.map { replacements[$0.id] ?? $0 } + incoming)
    }

    func updateGroupNotice(groupID: String, notice: String, allowEmpty: Bool = false) {
        guard allowEmpty || !notice.isEmpty, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups[index]
        groups[index] = GroupInfo(
            id: group.id,
            name: group.name,
            groupRevision: group.groupRevision,
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt,
            notice: notice,
            groupDescription: group.groupDescription,
            owner: group.owner,
            ownerID: group.ownerID,
            members: group.members,
            admins: group.admins,
            membersPartial: group.membersPartial,
            membersLoadedCount: group.membersLoadedCount,
            membersNextOffset: group.membersNextOffset,
            membersNextCursor: group.membersNextCursor,
            muted: group.muted,
            allMuted: group.allMuted,
            allMuteStart: group.allMuteStart,
            allMuteEnd: group.allMuteEnd,
            allMuteMode: group.allMuteMode,
            allMuteActive: group.allMuteActive,
            allMuteServerTime: group.allMuteServerTime,
            allMuteNextBoundary: group.allMuteNextBoundary,
            allMuteRepairRequired: group.allMuteRepairRequired,
            allMuteUpdatedAt: group.allMuteUpdatedAt,
            myRole: group.myRole,
            memberCount: group.memberCount,
            adminCount: group.adminCount,
            memberFriendApplyEnabled: group.memberFriendApplyEnabled,
            memberPreview: group.memberPreview,
            presentedRole: group.presentedRole,
            inviteConfirmRequired: group.inviteConfirmRequired,
            pendingJoinRequestCount: group.pendingJoinRequestCount,
            fileCount: group.fileCount,
            blacklistCount: group.blacklistCount,
            historyVisible: group.historyVisible,
            historyVisibleFromSeq: group.historyVisibleFromSeq,
            historyLimited: group.historyLimited,
            groupMuted: group.groupMuted,
            canManageMuteList: group.canManageMuteList,
            muteListCount: group.muteListCount
        )
    }

    func upsertGroupJoinRequest(groupID: String, request: GroupJoinRequest) {
        var items = groupJoinRequests[groupID] ?? []
        if let index = items.firstIndex(where: { $0.id == request.id }) {
            items[index] = request
        } else {
            items.insert(request, at: 0)
        }
        groupJoinRequests[groupID] = items
    }

    func ensureGroupConversationExists(_ group: GroupInfo, channelIDForConversation: ((ConversationMessageSnapshot) -> String)? = nil) {
        guard !isGroupConversationLocallyHidden(groupID: group.id) else { return }
        conversationStore.ensureGroupConversation(
            groupID: group.id,
            name: group.name,
            notice: group.notice,
            members: group.members,
            muted: group.muted,
            memberCount: shouldShowGroupMemberCount ? group.memberCount : nil,
            preservesMemberCountWhenMissing: shouldShowGroupMemberCount,
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt,
            avatarIsAuthoritative: true,
            accentHex: stableSeed(group.id),
            channelIDForConversation: channelIDForConversation ?? { self.remoteChannelID(for: $0) }
        )
    }

    func applyGroupHistoryBoundary(_ group: GroupInfo, channelIDForConversation: ((ConversationMessageSnapshot) -> String)? = nil) {
        applyHistoryVisibilityBoundaryForGroup(
            channelID: group.id,
            boundary: ConversationStore.HistoryVisibilityBoundary(
                fromSeq: group.historyVisibleFromSeq,
                limited: group.historyLimited,
                confirmed: true
            ),
            channelIDForConversation: channelIDForConversation
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

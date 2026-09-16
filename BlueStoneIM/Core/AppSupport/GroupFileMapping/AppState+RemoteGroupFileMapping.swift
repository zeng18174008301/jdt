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

// MARK: - AppState MainActor Partition
//
// Remote group/file mapping remains AppState/MainActor work because it mutates
// group, file, conversation, announcement, presence, and cache-backed stores
// observed by SwiftUI. Pure RemoteMessage payload decoding stays in
// MessageMapping as nonisolated helpers.

// MARK: - Remote Group and File Mapping

struct ResolvedGroupMuteFields {
    let allMuted: Bool
    let mode: GroupMuteMode?
    let active: Bool?
    let startAt: Date?
    let endAt: Date?
    let serverTime: Date?
    let nextBoundaryAt: Date?
    let repairRequired: Bool
    let updatedAt: String
}

extension AppState {
    func resolvedGroupMuteFields(
        allMuted: Bool,
        modeRawValue: String,
        active: Bool?,
        startAtRawValue: String?,
        endAtRawValue: String?,
        serverTimeRawValue: String?,
        nextBoundaryRawValue: String?,
        updatedAt: String?,
        repairRequired: Bool
    ) -> ResolvedGroupMuteFields {
        let startAt = parseRemoteDate(startAtRawValue)
        let endAt = parseRemoteDate(endAtRawValue)
        let serverTime = parseRemoteDate(serverTimeRawValue)
        let modeValue = modeRawValue.isEmpty ? nil : modeRawValue
        let persisted = try? GroupMuteModeState.projectPersisted(
            GroupMuteModeIntent(
                allMuted: allMuted,
                modeRawValue: modeValue,
                startAt: startAt,
                endAt: endAt
            ),
            atServerTime: serverTime ?? Date()
        )
        let requiresRepair = repairRequired || persisted?.projection.repairRequired == true
        return ResolvedGroupMuteFields(
            allMuted: allMuted,
            mode: persisted?.state?.mode,
            active: requiresRepair && allMuted ? true : active,
            startAt: startAt,
            endAt: endAt,
            serverTime: serverTime,
            nextBoundaryAt: parseRemoteDate(nextBoundaryRawValue),
            repairRequired: requiresRepair,
            updatedAt: updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    func groupMuteScopeKey(groupID: String, context: IMAPIContext) -> String {
        "\(remoteDataScopeKey(for: context))|group-mute|\(groupID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func scheduleGroupMuteBoundaryRefresh(for group: GroupInfo, context: IMAPIContext) {
        let key = groupMuteScopeKey(groupID: group.id, context: context)
        groupMuteBoundaryRefreshTasks[key]?.cancel()
        groupMuteBoundaryRefreshTasks[key] = nil
        guard let boundary = group.allMuteNextBoundary,
              let serverTime = group.allMuteServerTime,
              boundary > serverTime else { return }
        let delay = max(0.1, boundary.timeIntervalSince(serverTime))
        let scope = remoteDataScopeKey(for: context)
        let groupID = group.id
        groupMuteBoundaryRefreshTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400 * 366) * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            self.groupMuteBoundaryRefreshTasks[key] = nil
            await self.refreshGroupBundle(
                groupID: groupID,
                silent: true,
                includeSecondaryData: false,
                queueAfterInFlight: true
            )
        }
    }

    func applyRemoteGroups(_ remoteGroups: [RemoteUserGroup]) {
        let existing = groups.reduce(into: [String: GroupInfo]()) { result, group in
            let key = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, result[key] == nil else { return }
            result[key] = group
        }
        var seenGroupIDs: Set<String> = []
        var droppedDuplicateCount = 0
        groups = remoteGroups.compactMap { remoteGroup in
            let groupID = remoteGroup.groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupID.isEmpty else { return nil }
            guard seenGroupIDs.insert(groupID).inserted else {
                droppedDuplicateCount += 1
                return nil
            }
            return groupInfo(from: remoteGroup, existing: existing[groupID])
        }
        if droppedDuplicateCount > 0 {
            print("[JHT Perf] groups_sync_dedupe dropped=\(droppedDuplicateCount) input=\(remoteGroups.count)")
        }
        for group in groups {
            ensureGroupConversationExists(group)
            applyGroupHistoryBoundary(group)
            scheduleGroupMuteBoundaryRefresh(for: group, context: apiContext)
        }
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: remoteDataScopeKey(for: apiContext))
        }
        reapplyAllAvatarRealtimeProjections()
        scheduleRemoteSnapshotCacheWrite(scope: remoteDataScopeKey(for: apiContext))
    }

    func refreshGroupBundle(
        groupID: String,
        silent: Bool,
        includeSecondaryData: Bool = true,
        queueAfterInFlight: Bool = false
    ) async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let profileKey = groupMemberProfileCacheKey(groupID: groupID, context: context)
        let profileGenerationAtRequestStart = groupMemberProfileGenerationFloor(groupID: groupID)
        let announcementPrivacyEpochAtRequestStart = groupAnnouncementPrivacyEpoch
        let refreshEpoch = groupMemberProfileRefreshEpoch
        let groupRefreshEpoch = groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
        guard context.hasIMSession,
              isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
              ) else { return }
        let keyContext = contactStore.groupBundleRefreshKeyContext(
            tenantID: context.tenantID,
            imUID: context.imUID,
            groupID: groupID
        )
        let refreshKey = keyContext.refreshKey
        guard contactStore.beginGroupBundleRefresh(
            refreshKey: refreshKey,
            includeSecondaryData: includeSecondaryData,
            queueIfAlreadyRunning: queueAfterInFlight
        ) else { return }
        defer {
            reapplyAllAvatarRealtimeProjections()
            if contactStore.finishGroupBundleRefresh(refreshKey: refreshKey) {
                let currentContext = apiContext
                let currentScope = remoteDataScopeKey(for: currentContext)
                let currentProfileKey = groupMemberProfileCacheKey(
                    groupID: groupID,
                    context: currentContext
                )
                if currentContext.hasIMSession,
                   currentScope == scope,
                   currentProfileKey == profileKey,
                   group(id: groupID) != nil {
                    Task {
                        await refreshGroupBundle(
                            groupID: groupID,
                            silent: silent,
                            includeSecondaryData: true
                        )
                    }
                }
            }
        }
        do {
            let summary = try await groupSummaryWithLegacyFallback(context: context, groupID: groupID)
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return }
            await updateGroupSummary(
                groupID,
                from: summary,
                profileGenerationAtRequestStart: profileGenerationAtRequestStart,
                announcementPrivacyEpochAtRequestStart: announcementPrivacyEpochAtRequestStart
            )

            guard includeSecondaryData else { return }

            try await refreshGroupAnnouncementsData(context: context, scope: scope, groupID: groupID)
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return }

            let members = try await api.listGroupMembersPaged(
                context: context,
                groupID: groupID,
                limit: 100,
                offset: nil,
                cursor: nil,
                keyword: nil,
                role: nil
            )
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return }
            applyGroupMembers(
                members.items,
                selfMember: members.selfMember,
                total: members.total,
                groupID: groupID,
                partial: members.hasMore == true || (members.total ?? 0) > members.items.count,
                nextOffset: members.nextOffset,
                nextCursor: members.nextCursor,
                profileGenerationAtRequestStart: profileGenerationAtRequestStart
            )

            await refreshGroupFilesSnapshot(context: context, scope: scope, groupID: groupID, silent: silent)
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return }

            if canManageGroup(group(id: groupID) ?? groupInfo(from: summary.summary, summary: summary, existing: nil)) {
                do {
                    let requests = try await api.listGroupJoinRequests(context: context, groupID: groupID)
                    guard isCurrentGroupMemberProfileRefresh(
                        scope: scope,
                        key: profileKey,
                        globalEpoch: refreshEpoch,
                        groupEpoch: groupRefreshEpoch
                    ) else { return }
                    groupJoinRequests[groupID] = requests.map(groupJoinRequest(from:))
                } catch {
                    guard isCurrentGroupMemberProfileRefresh(
                        scope: scope,
                        key: profileKey,
                        globalEpoch: refreshEpoch,
                        groupEpoch: groupRefreshEpoch
                    ) else { return }
                    if case IMAPIError.forbidden(_) = error {
                        groupJoinRequests[groupID] = []
                    } else {
                        throw error
                    }
                }
            } else {
                guard isCurrentGroupMemberProfileRefresh(
                    scope: scope,
                    key: profileKey,
                    globalEpoch: refreshEpoch,
                    groupEpoch: groupRefreshEpoch
                ) else { return }
                groupJoinRequests[groupID] = []
            }
        } catch {
            guard isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
            ) else { return }
            #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
            let diagnosticHadSession = apiContext.hasRefreshSession || apiContext.hasIMSession
            #endif
            handleRemoteError(error, fallback: "群数据同步失败", silent: silent)
            #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
            if diagnosticHadSession, !apiContext.hasRefreshSession, !apiContext.hasIMSession {
                GroupForegroundSessionClearDiagnostics.recordClear(
                    origin: .groupBundleRemoteError,
                    scopeCurrent: true,
                    postAuthenticated: isAuthenticated,
                    postHasRefreshSession: apiContext.hasRefreshSession,
                    postHasIMSession: apiContext.hasIMSession
                )
            } else {
                GroupForegroundSessionClearDiagnostics.recordPostDecision(
                    scopeCurrent: isCurrentRemoteScope(scope),
                    postAuthenticated: isAuthenticated,
                    context: apiContext
                )
            }
            #endif
        }
    }

    func refreshGroupAnnouncements(groupID: String, silent: Bool) async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession else { return }
        let key = contactStore.groupBundleRefreshKeyContext(
            tenantID: context.tenantID, imUID: context.imUID, groupID: groupID
        ).refreshKey
        // Share the existing group refresh single-flight. A post-mutation
        // refresh must not borrow a pre-mutation GET through HTTP deduplication.
        guard contactStore.beginGroupBundleRefresh(refreshKey: key, includeSecondaryData: true,
                                                   queueIfAlreadyRunning: true) else { return }
        defer {
            if contactStore.finishGroupBundleRefresh(refreshKey: key), isCurrentRemoteScope(scope), group(id: groupID) != nil {
                Task { await refreshGroupBundle(groupID: groupID, silent: silent) }
            }
        }
        do {
            try await refreshGroupAnnouncementsData(context: context, scope: scope, groupID: groupID)
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            handleRemoteError(error, fallback: "群公告同步失败", silent: silent)
        }
    }

    private func refreshGroupAnnouncementsData(context: IMAPIContext, scope: String, groupID: String) async throws {
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        let startingAnnouncements = groupAnnouncements[groupID]
        let startingCurrent = currentGroupAnnouncements[groupID]
        let profileKey = groupMemberProfileCacheKey(groupID: groupID, context: context)
        let refreshEpoch = groupMemberProfileRefreshEpoch
        let groupEpoch = groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
        let api = self.api
        let currentTask = Task { try await api.currentGroupAnnouncement(context: context, groupID: groupID) }
        let listTask = Task { try await api.listGroupAnnouncements(context: context, groupID: groupID) }
        defer {
            currentTask.cancel()
            listTask.cancel()
        }
        let current = try await currentTask.value
        guard isCurrentRemoteScope(scope) else { return }
        let announcementData = try? await listTask.value
        guard isCurrentGroupMemberProfileRefresh(scope: scope, key: profileKey,
                globalEpoch: refreshEpoch, groupEpoch: groupEpoch),
              groupAnnouncements[groupID] == startingAnnouncements,
              currentGroupAnnouncements[groupID] == startingCurrent else { return }
        let existingAnnouncements = groupAnnouncements[groupID] ?? []
        var announcements = announcementData?.items.map { incoming in
            let mapped = groupAnnouncement(
                from: incoming,
                fallbackGroupID: groupID,
                requestPrivacyEpoch: announcementPrivacyEpoch
            )
            guard let existing = existingAnnouncements.first(where: { $0.id == mapped.id }) else { return mapped }
            return preferredGroupAnnouncement(existing: existing, incoming: mapped)
        } ?? existingAnnouncements
        if let current = current ?? announcementData?.current ?? announcementData?.topBanner {
            let mappedCurrent = groupAnnouncement(
                from: current,
                fallbackGroupID: groupID,
                requestPrivacyEpoch: announcementPrivacyEpoch
            )
            let currentAnnouncement = announcements.first(where: { $0.id == mappedCurrent.id })
                .map { preferredGroupAnnouncement(existing: $0, incoming: mappedCurrent) }
                ?? mappedCurrent
            if let index = announcements.firstIndex(where: { $0.id == currentAnnouncement.id }) {
                announcements[index] = currentAnnouncement
            } else {
                announcements.append(currentAnnouncement)
            }
            if currentAnnouncement.unread {
                currentGroupAnnouncements[groupID] = currentAnnouncement
            } else {
                currentGroupAnnouncements[groupID] = nil
            }
        } else {
            currentGroupAnnouncements[groupID] = nil
        }
        let ordered = orderedGroupAnnouncements(announcements)
        // A null unread banner plus a failed list is not an authoritative
        // empty publication list; retain the no-cache compatibility state.
        if announcementData != nil || current != nil || startingAnnouncements != nil {
            groupAnnouncements[groupID] = ordered
        }
        if let latest = ordered.first {
            updateGroupNotice(groupID: groupID, notice: latest.content.isEmpty ? latest.summary : latest.content)
        } else if announcementData != nil {
            // Only a successful authoritative empty list clears published
            // content. A null unread banner or failed list request does not.
            updateGroupNotice(groupID: groupID, notice: "", allowEmpty: true)
        }
    }

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
                    adminCount: detail.admins.count,
                    pendingJoinRequestCount: detail.settings.pendingJoinRequestCount,
                    fileCount: detail.settings.fileCount
                ),
                currentAnnouncement: detail.currentAnnouncement,
                settings: detail.settings
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
        let fallbackConversation = conversations.first { conversation in
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
            let acceptedSelfProjection = cacheMyGroupNickname(
                remoteSelf.groupNickname,
                groupID: groupID,
                generation: max(
                    effectiveResponseGeneration,
                    max(remoteSelf.groupMembershipGeneration, remoteSelf.revision)
                )
            )
            if acceptedSelfProjection {
                myGroupMemberProjectionsByScopedGroupKey[profileKey] = groupMemberUser(
                    from: remoteSelf,
                    fallback: currentUser
                )
            }
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
        } else if shouldShowGroupMemberCount, !users.isEmpty {
            groups[index].memberCount = max(groups[index].memberCount ?? 0, mergedUsers.count)
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
            memberCount: shouldShowGroupMemberCount ? groups[index].effectiveMemberCount : nil
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

    private func updateGroupNotice(groupID: String, notice: String, allowEmpty: Bool = false) {
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

    func ensureGroupConversationExists(_ group: GroupInfo) {
        guard !isGroupConversationLocallyHidden(groupID: group.id) else { return }
        conversationStore.ensureGroupConversation(
            groupID: group.id,
            name: group.name,
            notice: group.notice,
            members: group.members,
            muted: group.muted,
            memberCount: shouldShowGroupMemberCount ? group.effectiveMemberCount : nil,
            avatarURL: group.avatarURL,
            avatarVersion: group.avatarVersion,
            avatarUpdatedAt: group.avatarUpdatedAt,
            avatarIsAuthoritative: true,
            accentHex: stableSeed(group.id),
            channelIDForConversation: { self.remoteChannelID(for: $0) }
        )
    }

    func applyGroupHistoryBoundary(_ group: GroupInfo) {
        applyHistoryVisibilityBoundaryForGroup(
            channelID: group.id,
            boundary: ConversationStore.HistoryVisibilityBoundary(
                fromSeq: group.historyVisibleFromSeq,
                limited: group.historyLimited,
                confirmed: true
            )
        )
    }

    func groupInfo(from remote: RemoteUserGroup, detail: RemoteGroupDetail? = nil, summary: RemoteGroupSummary? = nil, existing: GroupInfo?) -> GroupInfo {
        let settings = detail?.settings ?? summary?.settings
        let incomingGroupRevision = max(remote.groupRevision, settings?.groupRevision ?? 0)
        let acceptsRevisionedProfile = existing == nil
            || (existing?.groupRevision ?? 0) <= 0
            || incomingGroupRevision >= (existing?.groupRevision ?? 0)
        let owner = detail?.owner ?? summary?.owner
        let summaryAdmins = summary?.memberPreview
            .filter { $0.isAdmin || $0.role == "admin" || $0.role == "owner" }
            .map { groupMemberUser(from: $0) }
        let admins = detail?.admins.map { groupMemberUser(from: $0) } ?? summaryAdmins ?? existing?.admins ?? []
        let groupID = remote.groupID.isEmpty ? existing?.id ?? "" : remote.groupID
        let notice: String
        if let announcements = groupAnnouncements[groupID] {
            // Unversioned group summary/detail fields cannot supersede the
            // revision-ordered publication cache, including known empty state.
            let latest = orderedGroupAnnouncements(announcements).first
            notice = latest.map { $0.content.isEmpty ? $0.summary : $0.content } ?? ""
        } else {
            notice = remote.notice.isEmpty
                ? (detail?.currentAnnouncement?.content ?? existing?.notice ?? "暂无群公告")
                : remote.notice
        }
        let groupName = acceptsRevisionedProfile
            ? (remote.name.isEmpty ? existing?.name ?? "" : remote.name)
            : existing?.name ?? remote.name
        let groupDescription = settings?.groupDescription
            ?? remote.groupDescription
            ?? existing?.groupDescription
            ?? ""
        let ownerID = owner.map { $0.imUID.isEmpty ? $0.userID : $0.imUID }.flatMap { $0.isEmpty ? nil : $0 } ?? (remote.ownerUID.isEmpty ? existing?.ownerID ?? "" : remote.ownerUID)
        let ownerDisplayName = owner.map { groupMemberUser(from: $0).name }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let decodedMemberCount = [
            detail?.memberCount,
            summary?.memberCount,
            summary?.counts.memberCount,
            remote.memberCount,
        ].compactMap { $0 }.max() ?? 0
        let memberCount = decodedMemberCount > 0
            ? decodedMemberCount
            : max(existing?.memberCount ?? 0, existing?.members.count ?? 0)
        let historyVisibleFromSeq = max(1, detail?.historyVisibleFromSeq ?? summary?.historyVisibleFromSeq ?? remote.historyVisibleFromSeq)
        let historyLimited = detail?.historyLimited ?? summary?.historyLimited ?? remote.historyLimited
        let resolvedRole = detail?.myRole ?? summary?.myRole ?? remote.myRole
        let fallbackCanManageMuteList = resolvedRole == "owner" || resolvedRole == "admin"
        let canManageMuteList = detail?.canManageMuteList
            ?? summary?.canManageMuteList
            ?? remote.canManageMuteList
            ?? settings?.canManageMuteList
            ?? existing?.canManageMuteList
            ?? fallbackCanManageMuteList
        let muteListCount = detail?.muteListCount
            ?? summary?.muteListCount
            ?? remote.muteListCount
            ?? settings?.muteListCount
            ?? existing?.muteListCount
        let groupMute = resolvedGroupMuteFields(
            allMuted: settings?.allMuted ?? remote.allMuted,
            modeRawValue: {
                let value = settings?.allMutedMode ?? ""
                return value.isEmpty ? remote.allMutedMode : value
            }(),
            active: settings?.allMutedActive ?? remote.allMutedActive,
            startAtRawValue: settings?.allMutedStartAt ?? remote.allMutedStartAt,
            endAtRawValue: settings?.allMutedEndAt ?? remote.allMutedEndAt,
            serverTimeRawValue: settings?.serverTime ?? remote.serverTime,
            nextBoundaryRawValue: settings?.nextBoundaryAt ?? remote.nextBoundaryAt,
            updatedAt: settings?.allMutedUpdatedAt ?? remote.allMutedUpdatedAt,
            repairRequired: (settings?.allMutedRepairRequired ?? false) || remote.allMutedRepairRequired
        )
        let normalizedAvatarSource = remote.avatarSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let authorityRequiresPlaceholder = normalizedAvatarSource == "group_default"
            || normalizedAvatarSource == "system_default"
            || isDefaultGroupAvatarURL(remote.avatar)
        var authoritativeAvatarURL = existing?.avatarURL ?? ""
        var authoritativeAvatarVersion = existing?.avatarVersion ?? ""
        var authoritativeAvatarUpdatedAt = existing?.avatarUpdatedAt ?? ""
        if acceptsRevisionedProfile && (remote.avatarProvided || authorityRequiresPlaceholder) {
            let stablePath = authorityRequiresPlaceholder ? "" : authoritativeGroupAvatarPath(remote.avatar)
            if stablePath.isEmpty {
                authoritativeAvatarURL = ""
                authoritativeAvatarVersion = ""
                authoritativeAvatarUpdatedAt = ""
            } else {
                let isSameAsset = stablePath == existing?.avatarURL
                authoritativeAvatarURL = stablePath
                authoritativeAvatarVersion = remote.avatarVersion.isEmpty && isSameAsset
                    ? existing?.avatarVersion ?? ""
                    : remote.avatarVersion
                authoritativeAvatarUpdatedAt = remote.avatarUpdatedAt.isEmpty && isSameAsset
                    ? existing?.avatarUpdatedAt ?? ""
                    : remote.avatarUpdatedAt
            }
        }
        return GroupInfo(
            id: groupID,
            name: groupName,
            groupRevision: max(incomingGroupRevision, existing?.groupRevision ?? 0),
            avatarURL: authoritativeAvatarURL,
            avatarVersion: authoritativeAvatarVersion,
            avatarUpdatedAt: authoritativeAvatarUpdatedAt,
            notice: notice,
            groupDescription: groupDescription,
            owner: ownerDisplayName ?? (remote.ownerName.isEmpty ? existing?.owner ?? remote.ownerUID : remote.ownerName),
            ownerID: ownerID,
            members: existing?.members ?? [],
            admins: admins,
            membersPartial: existing?.membersPartial ?? false,
            membersLoadedCount: existing?.membersLoadedCount ?? existing?.members.count ?? 0,
            membersNextOffset: existing?.membersNextOffset,
            membersNextCursor: existing?.membersNextCursor,
            muted: settings?.muted ?? remote.muted,
            allMuted: groupMute.allMuted,
            allMuteStart: groupMute.startAt,
            allMuteEnd: groupMute.endAt,
            allMuteMode: groupMute.mode,
            allMuteActive: groupMute.active,
            allMuteServerTime: groupMute.serverTime,
            allMuteNextBoundary: groupMute.nextBoundaryAt,
            allMuteRepairRequired: groupMute.repairRequired,
            allMuteUpdatedAt: groupMute.updatedAt,
            myRole: resolvedRole,
            memberCount: shouldShowGroupMemberCount ? memberCount : nil,
            inviteConfirmRequired: settings?.inviteConfirmRequired ?? remote.inviteConfirmRequired,
            pendingJoinRequestCount: settings?.pendingJoinRequestCount ?? summary?.counts.pendingJoinRequestCount ?? existing?.pendingJoinRequestCount ?? 0,
            fileCount: settings?.fileCount ?? summary?.counts.fileCount ?? existing?.fileCount ?? 0,
            blacklistCount: settings?.blacklistCount ?? existing?.blacklistCount ?? 0,
            historyVisible: settings?.historyVisible ?? existing?.historyVisible ?? true,
            historyVisibleFromSeq: historyVisibleFromSeq,
            historyLimited: historyLimited,
            groupMuted: detail?.groupMuted ?? summary?.groupMuted ?? remote.groupMuted,
            canManageMuteList: canManageMuteList,
            muteListCount: muteListCount
        )
    }

    func group(for conversation: Conversation) -> GroupInfo? {
        guard conversation.kind == .group else { return nil }
        let channelID = remoteChannelID(for: conversation)
        return groups.first { group in
            group.id == conversation.id
                || group.id == channelID
                || group.name == conversation.title
        }
    }

    private func fallbackUser(for member: RemoteUserGroupMember, existingMembers: [IMUser]) -> IMUser? {
        let identifiers = [member.imUID, member.userID, member.accountID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return nil }
        if identifiers.contains(where: { self.user(currentUser, matchesIdentifier: $0) }) {
            return currentUser
        }
        if let existing = existingMembers.first(where: { existing in
            identifiers.contains { self.user(existing, matchesIdentifier: $0) }
        }) {
            return existing
        }
        return contacts.first { contact in
            identifiers.contains { self.user(contact, matchesIdentifier: $0) }
        }
    }

    func groupMemberUser(from member: RemoteUserGroupMember, fallback: IMUser? = nil) -> IMUser {
        let avatar = member.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = member.imUID.isEmpty ? (fallback?.id ?? member.userID) : member.imUID
        let resolvedUserID = member.userID.isEmpty ? (fallback?.userID ?? resolvedID) : member.userID
        let resolvedUsername = member.accountID.isEmpty ? (fallback?.username ?? "") : member.accountID
        let identifiers = [resolvedID, resolvedUserID, resolvedUsername]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let isCurrentUser = identifiers.contains(where: { isCurrentUserIdentity($0) })
        let localRemark = isCurrentUser ? nil : contactRemarkValue(matching: identifiers)
        let globalNickname = [
            member.rawNickname,
            member.nickname,
            fallback?.name,
            resolvedUsername,
            resolvedUserID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let displayName = GroupMemberDisplayNameResolver.resolve(
            authoritativeDisplayName: member.displayName,
            viewerRemarks: [member.remark, localRemark],
            groupNickname: member.groupNickname,
            globalNickname: globalNickname,
            stableIdentifier: resolvedID,
            isCurrentUser: isCurrentUser
        )
        let resolvedAvatarURL = avatar.isEmpty ? fallback?.avatarURL ?? "" : resolveTenantAssetURL(avatar)
        let memberDepartmentName = member.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDepartmentPath = member.departmentPathNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasMemberDepartment = !memberDepartmentName.isEmpty || !memberDepartmentPath.isEmpty
        let department = hasMemberDepartment
            ? normalizedDepartmentName(member.departmentName, pathNames: member.departmentPathNames)
            : fallback?.department ?? ""
        let departmentPathNames = hasMemberDepartment
            ? normalizedDepartmentPathNames(member.departmentPathNames, fallbackName: department)
            : fallback?.departmentPathNames ?? []
        let user = IMUser(
            id: resolvedID,
            userID: resolvedUserID,
            username: resolvedUsername,
            name: displayName,
            title: "",
            department: department,
            departmentPathNames: departmentPathNames,
            phone: member.visiblePhone,
            email: "",
            status: presenceStatusText(
                rawStatus: member.presenceStatus,
                online: member.onlineKnown ? member.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(member.lastSeenAt),
            enterprise: currentEnterprise.name,
            avatarSeed: fallback?.avatarSeed ?? stableSeed(resolvedID),
            avatarURL: resolvedAvatarURL,
            avatarVersion: member.avatarVersion.isEmpty ? fallback?.avatarVersion ?? "" : member.avatarVersion,
            avatarUpdatedAt: member.avatarUpdatedAt.isEmpty ? fallback?.avatarUpdatedAt ?? "" : member.avatarUpdatedAt,
            badges: fallback?.badges ?? []
        )
        return presentationOverlaidUser(user)
    }

    private func applyCurrentUser(member: RemoteUserGroupMember) {
        let avatar = member.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDepartmentName = member.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberDepartmentPath = member.departmentPathNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasMemberDepartment = !memberDepartmentName.isEmpty || !memberDepartmentPath.isEmpty
        let department = hasMemberDepartment
            ? normalizedDepartmentName(member.departmentName, pathNames: member.departmentPathNames)
            : currentUser.department
        let departmentPathNames = hasMemberDepartment
            ? normalizedDepartmentPathNames(member.departmentPathNames, fallbackName: department)
            : currentUser.departmentPathNames
        currentUser = IMUser(
            id: member.imUID.isEmpty ? currentUser.id : member.imUID,
            userID: member.userID.isEmpty ? currentUser.userID : member.userID,
            username: currentUser.username,
            name: currentUser.name,
            title: "",
            department: department,
            departmentPathNames: departmentPathNames,
            phone: currentUser.phone,
            phoneVerified: currentUser.phoneVerified,
            realNameVerified: currentUser.realNameVerified,
            realNameStatus: currentUser.realNameStatus,
            email: currentUser.email,
            status: presenceStatusText(
                rawStatus: member.presenceStatus,
                online: member.onlineKnown ? member.online : nil
            ),
            lastLoginAt: resolvedLastLoginText(member.lastSeenAt),
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(member.imUID.isEmpty ? currentUser.id : member.imUID),
            avatarURL: avatar.isEmpty ? currentUser.avatarURL : resolveTenantAssetURL(avatar),
            avatarVersion: member.avatarVersion.isEmpty ? currentUser.avatarVersion : member.avatarVersion,
            avatarUpdatedAt: member.avatarUpdatedAt.isEmpty ? currentUser.avatarUpdatedAt : member.avatarUpdatedAt,
            badges: []
        )
    }

    func groupAnnouncement(
        from remote: RemoteGroupAnnouncement,
        fallbackGroupID: String = "",
        requestPrivacyEpoch: UInt64? = nil
    ) -> GroupAnnouncement {
        let mapped = GroupAnnouncement(
            id: remote.id,
            groupID: remote.groupID.isEmpty ? fallbackGroupID : remote.groupID,
            title: remote.title.isEmpty ? "群公告" : remote.title,
            content: remote.content,
            summary: remote.summary.isEmpty ? remote.content : remote.summary,
            createdBy: remote.createdBy,
            status: remote.status,
            createdAt: displayTime(remote.createdAt),
            updatedAt: remote.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            publishedAt: displayTime(remote.publishedAt ?? remote.createdAt),
            unread: remote.unread,
            readAt: remote.readAt,
            displayPosition: remote.displayPosition,
            readAction: remote.readAction,
            readCount: remote.readCount,
            unreadCount: remote.unreadCount,
            recipientCount: remote.recipientCount,
            canViewReadCounts: remote.canViewReadCounts
        )
        guard let requestPrivacyEpoch else { return mapped }
        return GroupAnnouncementPrivacyProjection.sanitize(
            mapped,
            requestEpoch: requestPrivacyEpoch,
            currentEpoch: groupAnnouncementPrivacyEpoch
        )
    }

    func upsertGroupAnnouncement(_ announcement: GroupAnnouncement, markCurrentRead: Bool) {
        guard !announcement.id.isEmpty else { return }
        var items = groupAnnouncements[announcement.groupID] ?? []
        let accepted = items.first(where: { $0.id == announcement.id })
            .map { preferredGroupAnnouncement(existing: $0, incoming: announcement) }
            ?? announcement
        items.removeAll { $0.id == announcement.id }
        items.insert(accepted, at: 0)
        let ordered = orderedGroupAnnouncements(items)
        groupAnnouncements[announcement.groupID] = ordered
        if let latest = ordered.first {
            updateGroupNotice(groupID: announcement.groupID, notice: latest.content.isEmpty ? latest.summary : latest.content)
        }
        if markCurrentRead || !accepted.unread {
            if currentGroupAnnouncements[accepted.groupID]?.id == accepted.id {
                currentGroupAnnouncements[accepted.groupID] = nil
            }
        } else {
            currentGroupAnnouncements[accepted.groupID] = accepted
        }
    }

    private func preferredGroupAnnouncement(existing: GroupAnnouncement, incoming: GroupAnnouncement) -> GroupAnnouncement {
        GroupAnnouncementRevisionProjection.preferred(
            existing: existing,
            incoming: incoming,
            existingRevision: parseRemoteDate(existing.updatedAt),
            incomingRevision: parseRemoteDate(incoming.updatedAt)
        )
    }

    private func orderedGroupAnnouncements(_ announcements: [GroupAnnouncement]) -> [GroupAnnouncement] {
        // current means latest unread, not latest published/edited. Keep that
        // banner selection independent from the list and editor's latest item.
        announcements.enumerated().sorted { left, right in
            let leftRevision = parseRemoteDate(left.element.updatedAt) ?? .distantPast
            let rightRevision = parseRemoteDate(right.element.updatedAt) ?? .distantPast
            return leftRevision == rightRevision ? left.offset < right.offset : leftRevision > rightRevision
        }.map(\.element)
    }

    func clearGroupAnnouncementReadCounts(groupID: String? = nil) {
        groupAnnouncementPrivacyEpoch &+= 1
        for key in Array(groupAnnouncements.keys) where groupID == nil || key == groupID {
            groupAnnouncements[key] = groupAnnouncements[key]?.map { $0.scrubbingReadCounts() }
        }
        for key in Array(currentGroupAnnouncements.keys) where groupID == nil || key == groupID {
            currentGroupAnnouncements[key] = currentGroupAnnouncements[key]?.scrubbingReadCounts()
        }
    }

    func groupJoinRequest(from remote: RemoteGroupJoinRequest) -> GroupJoinRequest {
        GroupJoinRequest(
            id: remote.id,
            groupID: remote.groupID,
            applicantUID: remote.applicantUID,
            applicantName: remote.applicantName.isEmpty ? remote.applicantUID : remote.applicantName,
            applicantAvatarURL: resolveTenantAssetURL(remote.applicantAvatar),
            inviterAvatarURL: resolveTenantAssetURL(remote.inviterAvatar),
            inviterName: remote.inviterName,
            status: remote.status,
            message: remote.message.isEmpty ? "申请加入群聊" : remote.message,
            createdAt: displayTime(remote.createdAt)
        )
    }

    func fileItem(from remote: RemoteGroupFile, groupID: String) -> FileItem {
        var item = fileItem(from: remote, fallbackSource: group(id: groupID)?.name ?? conversationTitleForGroupFileList(groupID: groupID))
        if item.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.channelID = groupID
        }
        if item.channelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.channelType = "group"
        }
        return item
    }

    func fileItem(from remote: RemoteGroupFile) -> FileItem {
        let knownConversationTitle = conversations.first { conversation in
            conversation.id == remote.channelID || remoteChannelID(for: conversation) == remote.channelID
        }?.title
        return fileItem(from: remote, fallbackSource: remote.sourceName.isEmpty ? knownConversationTitle ?? remote.channelID : remote.sourceName)
    }

    func favoriteAssetItem(from remote: RemoteFavoriteAssetItem) -> FavoriteAssetItem {
        let file = fileItem(fromFavoriteAsset: remote)
        let messageID = remote.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        return FavoriteAssetItem(
            messageID: messageID.isEmpty ? favoriteAssetFallbackMessageID(remote) : messageID,
            tenantID: remote.tenantID,
            channelID: remote.channelID,
            channelType: remote.channelType,
            channelSeq: remote.channelSeq,
            fromUID: remote.resolvedSenderID,
            contentType: remote.contentType,
            status: remote.status,
            createdAt: remote.createdAt,
            favoritedAt: remote.favoritedAt,
            favoriteVersion: remote.favoriteVersion,
            category: favoriteAssetCategory(from: remote, file: file),
            displayText: remote.displayText,
            cursor: remote.cursor,
            file: file,
            isUnavailable: favoriteAssetIsUnavailable(remote)
        )
    }

    func fileItem(fromFavoriteAsset remote: RemoteFavoriteAssetItem) -> FileItem {
        let payload = remote.payload
        let category = favoriteAssetCategory(from: remote)
        let unavailable = favoriteAssetIsUnavailable(remote)
        let fileID = attachmentPayloadString(
            payload,
            ["file_id", "remote_file_id", "attachment_id", "media_id", "asset_file_id", "id"]
        )
        let fallbackMessageID = favoriteAssetFallbackMessageID(remote)
        let itemID = fileID.isEmpty ? "favorite-asset|\(fallbackMessageID)" : fileID
        let displayText = remote.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadName = attachmentPayloadString(
            payload,
            ["file_name", "filename", "name", "attachment_name", "title", "display_name"]
        )
        let name = [payloadName, displayText].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? (unavailable ? "内容已失效" : "未命名资料")
        let mimeType = attachmentPayloadString(payload, ["mime_type", "mime", "content_type"])
        let extensionValue = attachmentPayloadString(payload, ["extension", "file_extension", "ext"])
        let mediaCategory = favoriteAssetMediaCategory(remote: remote, fallback: category)
        let previewURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["preview_url", "preview", "url"]))
        let downloadURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["download_url", "download_public", "file_url", "url", "asset_url"]))
        let thumbnailURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["thumbnail_url", "thumb_url", "preview_thumbnail_url", "thumbnail_preview_url"]))
        let posterURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["poster_url", "video_poster_url"]))
        let coverURL = unavailable ? "" : resolvedTenantFileAssetURL(attachmentPayloadString(payload, ["cover_url", "video_cover_url"]))
        let previewKind = attachmentPayloadString(payload, ["preview_kind"])
        let contentDisposition = attachmentPayloadString(payload, ["content_disposition"])
        let previewAvailable = unavailable ? false : attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition,
            backendAvailable: attachmentPayloadBool(payload, ["preview_available"])
        )
        let downloadAvailable = unavailable ? false : (attachmentPayloadBool(payload, ["download_available"]) ?? (!downloadURL.isEmpty || !fileID.isEmpty))
        let senderDisplayName = attachmentPayloadString(
            payload,
            ["sender_display_name", "sender_name", "from_name", "nickname", "display_name"]
        )
        let senderID = remote.resolvedSenderID
        let source = favoriteAssetSourceText(remote)
        let status: String
        if unavailable {
            status = "内容已失效/不可预览"
        } else if previewAvailable && downloadAvailable {
            status = "可预览 / 可下载"
        } else if downloadAvailable {
            status = "可下载"
        } else if previewAvailable {
            status = "可预览"
        } else {
            status = "仅元数据"
        }
        return FileItem(
            id: itemID,
            name: name,
            type: fileTypeLabel(name: name, mimeType: mimeType, category: mediaCategory, fallback: extensionValue),
            size: byteSize(attachmentPayloadInt64(payload, ["size_bytes", "size", "file_size"]) ?? 0),
            sizeBytes: attachmentPayloadInt64(payload, ["size_bytes", "size", "file_size"]),
            owner: senderDisplayName.isEmpty ? (senderID.isEmpty ? "未知发送人" : senderID) : senderDisplayName,
            source: source,
            time: displayTime(remote.favoritedAt ?? remote.createdAt),
            scope: "个人收藏",
            status: status,
            accentHex: stableSeed(itemID),
            remoteFileID: fileID,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: downloadAvailable,
            channelID: remote.channelID,
            channelType: remote.channelType,
            channelSeq: remote.channelSeq,
            mediaCategory: mediaCategory,
            contentType: remote.contentType,
            kind: attachmentPayloadString(payload, ["kind", "type"]),
            mimeType: mimeType,
            cacheKey: attachmentPayloadString(payload, ["cache_key", "cacheKey", "version"]),
            version: attachmentPayloadString(payload, ["version", "file_version", "cache_version"]),
            checksum: attachmentPayloadString(payload, ["checksum"]),
            fileExtension: extensionValue,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: previewKind,
            contentDisposition: contentDisposition,
            width: attachmentPayloadInt64(payload, ["width"]).map(Int.init),
            height: attachmentPayloadInt64(payload, ["height"]).map(Int.init),
            durationSeconds: attachmentDuration(from: payload)
        )
    }

    private func favoriteAssetFallbackMessageID(_ remote: RemoteFavoriteAssetItem) -> String {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：收藏 fallback ID 纯逻辑从 AppState 拆出
        FileItemProjectionHelper.favoriteAssetFallbackMessageID(remote)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func favoriteAssetCategory(from remote: RemoteFavoriteAssetItem, file: FileItem? = nil) -> FavoriteAssetCategory {
        let explicit = FavoriteAssetCategory(serverValue: remote.category)
        if explicit != .all {
            return explicit
        }
        if let file {
            for category in FavoriteAssetCategory.displayOrder where category != .all && category.matches(file: file) {
                return category
            }
        }
        return FavoriteAssetCategory(serverValue: favoriteAssetMediaCategory(remote: remote, fallback: .all))
    }

    private func favoriteAssetMediaCategory(remote: RemoteFavoriteAssetItem, fallback: FavoriteAssetCategory) -> String {
        let payload = remote.payload
        let category = attachmentPayloadString(payload, ["media_category", "category", "kind", "preview_kind"])
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：收藏媒体分类纯逻辑从 AppState 拆出
        return FileItemProjectionHelper.favoriteAssetMediaCategory(
            payloadCategory: category,
            contentType: remote.contentType,
            fallback: fallback
        )
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func favoriteAssetSourceText(_ remote: RemoteFavoriteAssetItem) -> String {
        if let conversation = conversations.first(where: { conversation in
            conversation.id == remote.channelID || remoteChannelID(for: conversation) == remote.channelID
        }) {
            return conversation.title
        }
        switch remote.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "group":
            return remote.channelID.isEmpty ? "群聊" : "群聊 \(remote.channelID)"
        case "direct", "p2p":
            return "私聊"
        default:
            return remote.channelID.isEmpty ? "收藏资料" : remote.channelID
        }
    }

    private func favoriteAssetIsUnavailable(_ remote: RemoteFavoriteAssetItem) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：收藏失效状态纯判断从 AppState 拆出
        FileItemProjectionHelper.favoriteAssetIsUnavailable(remote)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    func fileItem(from detail: RemoteUserFileDetail, fallback: FileItem) -> FileItem {
        let object = detail.file
        let remote = RemoteGroupFile(
            fileID: object.id,
            name: object.fileName,
            type: fallback.type,
            mimeType: object.mimeType,
            category: "",
            size: object.sizeBytes,
            uploaderUID: object.uploaderUID,
            uploaderName: fallback.owner,
            channelID: fallback.channelID,
            channelType: fallback.channelType,
            channelSeq: fallback.channelSeq,
            groupID: fallback.channelType == "group" ? fallback.channelID : "",
            sourceName: fallback.source,
            createdAt: object.createdAt,
            previewAvailable: detail.previewAvailable,
            downloadAvailable: detail.downloadAvailable,
            previewURL: detail.previewURL,
            downloadURL: detail.downloadURL,
            status: object.status,
            cacheKey: object.cacheKey,
            version: object.version,
            checksum: object.checksum,
            mediaCategory: object.mediaCategory,
            contentType: object.contentType,
            kind: object.kind,
            fileExtension: object.fileExtension,
            thumbnailURL: object.thumbnailURL,
            posterURL: object.posterURL,
            coverURL: object.coverURL,
            previewKind: object.previewKind,
            contentDisposition: detail.contentDisposition,
            width: object.width,
            height: object.height,
            durationSeconds: object.durationSeconds
        )
        return fileItem(from: remote, fallbackSource: fallback.source)
    }

    func fileItem(from remote: RemoteGroupFile, fallbackSource: String) -> FileItem {
        let type = fileTypeLabel(name: remote.name, mimeType: remote.mimeType, category: remote.mediaCategory.isEmpty ? remote.category : remote.mediaCategory, fallback: remote.type)
        let previewURL = resolvedTenantFileAssetURL(remote.previewURL)
        let downloadURL = resolvedTenantFileAssetURL(remote.downloadURL)
        let thumbnailURL = resolvedTenantFileAssetURL(remote.thumbnailURL)
        let posterURL = resolvedTenantFileAssetURL(remote.posterURL)
        let coverURL = resolvedTenantFileAssetURL(remote.coverURL)
        let previewAvailable = attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: remote.previewKind,
            contentDisposition: remote.contentDisposition,
            backendAvailable: remote.previewAvailable
        )
        let status: String
        if !remote.status.isEmpty, remote.status.lowercased() != "uploaded" {
            status = remote.status
        } else if remote.downloadAvailable && previewAvailable {
            status = "可预览 / 可下载"
        } else if remote.downloadAvailable {
            status = "可下载"
        } else if previewAvailable {
            status = "可预览"
        } else {
            status = "仅元数据"
        }
        return FileItem(
            id: remote.fileID.isEmpty ? remote.name : remote.fileID,
            name: remote.name.isEmpty ? "未命名文件" : remote.name,
            type: type,
            size: byteSize(remote.size),
            sizeBytes: remote.size,
            owner: remote.uploaderName.isEmpty ? remote.uploaderUID : remote.uploaderName,
            source: remote.sourceName.isEmpty ? fallbackSource : remote.sourceName,
            time: displayTime(remote.createdAt),
            scope: remote.channelScopeText,
            status: status,
            accentHex: stableSeed(remote.fileID),
            remoteFileID: remote.fileID,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: remote.downloadAvailable,
            channelID: remote.channelID,
            channelType: remote.channelType,
            channelSeq: remote.channelSeq,
            mediaCategory: remote.mediaCategory.isEmpty ? remote.category : remote.mediaCategory,
            contentType: remote.contentType,
            kind: remote.kind.isEmpty ? remote.type : remote.kind,
            mimeType: remote.mimeType,
            cacheKey: remote.cacheKey,
            version: remote.version,
            checksum: remote.checksum,
            fileExtension: remote.fileExtension,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: remote.previewKind,
            contentDisposition: remote.contentDisposition,
            width: remote.width,
            height: remote.height,
            durationSeconds: remote.durationSeconds
        )
    }

    func refreshKnownGroupFileItemsForFileList(
        context: IMAPIContext,
        scope: String,
        query: String,
        category: String,
        excludingFileIDs: Set<String>
    ) async -> [FileItem] {
        let groupIDs = knownGroupIDsForFileList()
        guard !groupIDs.isEmpty else { return [] }
        var seen = excludingFileIDs
        var collected: [FileItem] = []
        for groupID in groupIDs.prefix(30) {
            guard isCurrentRemoteScope(scope) else { return collected }
            do {
                let remoteFiles = try await api.listGroupFiles(context: context, groupID: groupID)
                let mapped = remoteFiles
                    .map { fileItem(from: $0, groupID: groupID) }
                    .filter(isFileItemVisibleInFileLists)
                fileStore.replaceGroupFiles(mapped, groupID: groupID)
                for item in mapped where seen.insert(item.id).inserted && fileItem(item, matchesQuery: query, category: category) {
                    collected.append(item)
                }
            } catch {
                logSyncEndpointFailure("/api/tenant/groups/{id}/files", error: error)
            }
        }
        return collected
    }

    private func knownGroupIDsForFileList() -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        func append(_ rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            ids.append(value)
        }
        for conversation in conversations where conversation.kind == .group {
            append(remoteChannelID(for: conversation))
        }
        for group in groups {
            append(group.id)
        }
        return ids
    }

    func backfillRecentAttachmentMessagesForFileList(
        context: IMAPIContext,
        scope: String
    ) async {
        let targets = fileListMessageBackfillTargets(
            conversationLimit: fileListMessageBackfillConversationLimit,
            windowLimit: fileListMessageBackfillWindowLimit
        )
        guard !targets.isEmpty else { return }
        for target in targets {
            guard isCurrentRemoteScope(scope) else { return }
            let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: target.channelID, channelType: target.channelType)
            do {
                let page = try await api.syncMessages(
                    context: context,
                    channelID: target.channelID,
                    channelType: target.channelType,
                    afterSeq: target.afterSeq,
                    beforeSeq: nil,
                    limit: fileListMessageBackfillWindowLimit
                )
                guard isCurrentRemoteScope(scope),
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: target.channelID, channelType: target.channelType, generation: boundaryGeneration) else { return }
                let syncBoundary = historyBoundary(from: page, channelType: target.channelType)
                let relevantMessages = page.items.filter { remote in
                    isRemoteMessageVisibleAfterHistoryBoundary(remote, boundary: syncBoundary)
                        && isAttachmentMessageKind(remoteMessageKind(from: remote))
                        && !isVoiceMessageAssetForFileList(remote)
                }
                guard !relevantMessages.isEmpty else {
                    if let syncBoundary {
                        applyHistoryVisibilityBoundaryForGroup(
                            channelID: target.channelID,
                            boundary: syncBoundary
                        )
                    }
                    continue
                }
                applyRemoteMessages(
                    relevantMessages,
                    channelID: target.channelID,
                    channelType: target.channelType,
                    windowRetention: .latestTail(limit: fileListMessageBackfillWindowLimit),
                    historyBoundary: syncBoundary
                )
            } catch {
                logSyncEndpointFailure("/api/im/sync", error: error)
            }
        }
    }

    private func fileListMessageBackfillTargets(
        conversationLimit: Int,
        windowLimit: Int
    ) -> [(channelID: String, channelType: String, afterSeq: Int64)] {
        var seen = Set<String>()
        var targets: [(channelID: String, channelType: String, afterSeq: Int64)] = []
        let boundedLimit = max(1, conversationLimit)
        let boundedWindow = Int64(max(1, windowLimit))
        for conversation in conversations {
            guard conversation.kind != .system else { continue }
            let channelID = remoteChannelID(for: conversation)
            let channelType = apiChannelType(for: conversation.kind)
            let key = "\(channelType)|\(channelID)"
            guard !channelID.isEmpty, seen.insert(key).inserted else { continue }
            // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：附件补扫目标计算避免生成序号临时数组
            let localLatestSeq = ConversationSequenceInspector.maximumChannelSeq(in: conversation.messages) ?? 0
            // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
            let latestKnownSeq = max(conversation.lastMsgSeq, localLatestSeq)
            let shouldBackfill = latestKnownSeq > localLatestSeq
                || fileListMessageSummaryLooksLikeAttachment(conversation.lastMessage)
                || fileListMessageSummaryLooksLikeAttachment(conversation.subtitle)
            guard shouldBackfill else { continue }
            targets.append((
                channelID: channelID,
                channelType: channelType,
                afterSeq: max(0, latestKnownSeq - boundedWindow)
            ))
            if targets.count >= boundedLimit {
                break
            }
        }
        return targets
    }

    private func fileListMessageSummaryLooksLikeAttachment(_ rawValue: String) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：附件摘要识别复用静态后缀集合
        FileItemProjectionHelper.fileListMessageSummaryLooksLikeAttachment(rawValue)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func isVoiceMessageAssetForFileList(_ remote: RemoteMessage) -> Bool {
        let payload = remote.payload
        return VoiceFileListPolicy.isVoiceMessageAsset(
            contentType: remote.contentType,
            mediaCategory: attachmentPayloadString(payload, ["media_category", "category"]),
            kind: attachmentPayloadString(payload, ["kind", "type"]),
            previewKind: attachmentPayloadString(payload, ["preview_kind"]),
            type: attachmentPayloadString(payload, ["type"]),
            name: attachmentPayloadString(payload, ["file_name", "filename", "name"]),
            mimeType: attachmentPayloadString(payload, ["mime_type", "mime"]),
            fileExtension: attachmentPayloadString(payload, ["extension", "file_extension", "ext"])
        )
    }

    func fileItemsReferToSameAttachment(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件去重纯判断从 AppState 拆出
        FileItemProjectionHelper.fileItemsReferToSameAttachment(lhs, rhs)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func conversationTitleForGroupFileList(groupID: String) -> String {
        conversations.first { conversation in
            conversation.kind == .group && (conversation.id == groupID || remoteChannelID(for: conversation) == groupID)
        }?.title ?? groupID
    }

    func attachmentFileItems(from conversations: [Conversation]) -> [FileItem] {
        var seen = Set<String>()
        var items: [FileItem] = []
        for conversation in conversations {
            for message in conversation.messages.reversed() {
                guard let item = fileItem(fromAttachmentMessage: message, conversation: conversation),
                      seen.insert(item.id).inserted else {
                    continue
                }
                items.append(item)
            }
        }
        return items
    }

    func fileItem(fromAttachmentMessage message: ChatMessage, conversation: Conversation) -> FileItem? {
        guard isAttachmentMessageKind(message.kind),
              message.status != .sending,
              message.status != .failed,
              message.status != .recalled,
              !message.isDeletedLocally else {
            return nil
        }
        let remoteFileID = (message.attachmentFileID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackID = attachmentFallbackFileID(for: message, conversation: conversation)
        let fileID = remoteFileID.isEmpty ? fallbackID : remoteFileID
        guard !fileID.isEmpty else { return nil }
        let name = (message.attachmentName ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? "未命名文件" : name
        let mediaCategory = attachmentMediaCategory(for: message)
        let mimeType = attachmentMimeType(from: message)
        guard !VoiceFileListPolicy.isVoiceMessageAsset(
            contentType: message.contentType,
            mediaCategory: mediaCategory,
            kind: message.kind.rawValue,
            previewKind: message.attachmentPreviewKind,
            type: message.attachmentExtension,
            name: resolvedName,
            mimeType: mimeType,
            fileExtension: message.attachmentExtension
        ) else {
            return nil
        }
        let previewURL = resolvedTenantFileAssetURL(message.attachmentPreviewURL)
        let downloadURL = resolvedTenantFileAssetURL(message.attachmentDownloadURL)
        let thumbnailURL = resolvedTenantFileAssetURL(message.attachmentThumbnailURL)
        let posterURL = resolvedTenantFileAssetURL(message.attachmentPosterURL)
        let coverURL = resolvedTenantFileAssetURL(message.attachmentCoverURL)
        let previewAvailable = attachmentPreviewAllowed(
            previewURL: previewURL,
            previewKind: message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            backendAvailable: message.attachmentPreviewAvailable
        )
        let downloadAvailable = !downloadURL.isEmpty || !remoteFileID.isEmpty
        let status: String
        if previewAvailable && downloadAvailable {
            status = "可预览 / 可下载"
        } else if downloadAvailable {
            status = "可下载"
        } else if previewAvailable {
            status = "可预览"
        } else {
            status = "待同步"
        }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        return FileItem(
            id: fileID,
            name: resolvedName,
            type: fileTypeLabel(name: resolvedName, mimeType: mimeType, category: mediaCategory, fallback: message.attachmentExtension),
            size: byteSize(message.attachmentSizeBytes ?? 0),
            sizeBytes: message.attachmentSizeBytes,
            owner: remarkPreferredDisplayName(
                identifiers: [message.senderId],
                candidates: [message.senderName],
                fallback: message.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message.senderId : message.senderName
            ),
            source: conversation.title,
            time: message.createdAt.map(displayTime) ?? message.time,
            scope: conversation.kind == .group ? "群文件" : (conversation.kind == .direct ? "私聊文件" : "会话文件"),
            status: status,
            accentHex: stableSeed(fileID),
            remoteFileID: remoteFileID,
            previewURL: previewURL,
            downloadURL: downloadURL,
            previewAvailable: previewAvailable,
            downloadAvailable: downloadAvailable,
            channelID: channelID,
            channelType: channelType,
            channelSeq: message.channelSeq,
            mediaCategory: mediaCategory,
            contentType: message.contentType,
            kind: message.kind.rawValue,
            mimeType: mimeType,
            cacheKey: message.attachmentCacheKey,
            version: message.attachmentVersion,
            checksum: message.attachmentChecksum,
            fileExtension: message.attachmentExtension,
            thumbnailURL: thumbnailURL,
            posterURL: posterURL,
            coverURL: coverURL,
            previewKind: message.attachmentPreviewKind,
            contentDisposition: message.attachmentContentDisposition,
            width: message.attachmentWidth,
            height: message.attachmentHeight,
            durationSeconds: message.attachmentDurationSeconds
        )
    }

    private func attachmentFallbackFileID(for message: ChatMessage, conversation: Conversation) -> String {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：本地附件 fallback ID 纯逻辑从 AppState 拆出
        FileItemProjectionHelper.attachmentFallbackFileID(for: message, conversation: conversation)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    func fileItem(_ fileItem: FileItem, matchesQuery query: String, category: String) -> Bool {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件列表过滤纯逻辑从 AppState 拆出并复用静态分类集合
        FileItemProjectionHelper.fileItem(fileItem, matchesQuery: query, category: category)
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    func mergeGroupFiles(_ fileItems: [FileItem]) {
        fileStore.mergeGroupFiles(fileItems.filter(isFileItemVisibleInFileLists))
    }

    func upsertTenantFile(_ file: FileItem) {
        guard isFileItemVisibleInFileLists(file) else { return }
        fileStore.upsertTenantFile(file)
    }

    private func fileTypeLabel(name: String, mimeType: String, category: String, fallback: String) -> String {
        // JHT_MOD_BEGIN APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改开始：文件类型展示纯逻辑从 AppState 拆出
        FileItemProjectionHelper.fileTypeLabel(
            name: name,
            mimeType: mimeType,
            category: category,
            fallback: fallback
        )
        // JHT_MOD_END APPSTATE_FILE_ITEM_PROJECTION_HELPER_PERF_20260913 - 修改结束
    }

    private func statusText(_ status: String) -> String {
        switch status.lowercased() {
        case "online":
            return "在线"
        case "offline":
            return "离线"
        case "hidden", "unknown", "normal", "active", "enabled":
            return ""
        case "busy":
            return "忙碌"
        default:
            return status.isEmpty ? "" : status
        }
    }

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
        currentUser = userWithPresenceStatus(
            currentUser,
            status: hidesPresence ? "" : currentUser.status,
            lastLoginAt: hidesLastLogin ? "" : currentUser.lastLoginAt
        )
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
        conversationStore.conversations = conversations.map { conversation in
            var next = conversation
            next.participants = conversation.participants.map { user in
                userWithPresenceStatus(
                    user,
                    status: hidesPresence ? "" : user.status,
                    lastLoginAt: hidesLastLogin ? "" : user.lastLoginAt
                )
            }
            return next
        }
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
    private func remoteConversationActivityDate(_ remote: RemoteConversation, previous: Conversation?) -> Date? {
        RemoteConversationTimelineMapper.activityDate(remote: remote, previous: previous)
    }

    private func remoteConversationTime(_ remote: RemoteConversation, previous: Conversation?, activityDate: Date?) -> String {
        RemoteConversationTimelineMapper.displayTime(remote: remote, previous: previous, activityDate: activityDate)
    }

    func remoteConversationSortTimestamp(_ remote: RemoteConversation, previous: Conversation? = nil) -> TimeInterval {
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
        previous: Conversation?,
        participants: [IMUser]
    ) -> Int? {
        guard kind == .group else { return participants.count }
        guard shouldShowGroupMemberCount else { return nil }
        if let group = groups.first(where: { $0.id == channelID || $0.id == previous?.id }),
           group.effectiveMemberCount > 0 {
            return group.effectiveMemberCount
        }
        if let previousCount = previous?.memberCount, previousCount > 0 {
            return previousCount
        }
        if let previousParticipantCount = previous?.participants.count, previousParticipantCount > 0 {
            return previousParticipantCount
        }
        return participants.count
    }

    func applyRemoteConversations(_ remoteConversations: [RemoteConversation], replacing: Bool) {
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
                    conversations,
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
                participants: participants
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
            let readStateKey = conversationReadStateKey(channelID: channelID, channelType: normalizedChannelType)
            let readWatermarkScope = currentReadWatermarkScope(channelID: channelID, channelType: normalizedChannelType)
            let exactReadSeq = conversationStore.effectiveReadSeq(readStateKey: readStateKey, scope: readWatermarkScope)
            let legacyReadSeq = readWatermarkScope == nil ? locallyReadSeq(for: remote) : 0
            let lastReadSeq = max(previous?.lastReadSeq ?? 0, remote.lastReadSeq, legacyReadSeq, exactReadSeq)
            let latestSeq = remoteConversationLatestSeq(remote)
            let staleUnreadProjection = exactReadSeq > remote.lastReadSeq
            let locallyReadThrough: Bool
            if latestSeq > 0 {
                locallyReadThrough = lastReadSeq >= latestSeq
            } else {
                locallyReadThrough = readWatermarkScope == nil && isConversationLocallyReadThrough(remote)
            }
            let rawUnreadState = resolvedConversationUnreadState(
                remoteUnreadCount: staleUnreadProjection ? previous?.unread ?? 0 : remote.unreadCount,
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
            let mappedLastMessagePreview = rtcListConflictSeq == nil
                ? boundedLastMessage.map { messagePreview($0, participants: participants) } ?? previous?.lastMessage ?? ""
                : previous?.lastMessage ?? ""
            let mappedTime = rtcListConflictSeq == nil ? time : previous?.time ?? ""
            let mappedSortTimestamp = rtcListConflictSeq == nil ? sortTimestamp : previous?.sortTimestamp ?? 0
            var mapped = Conversation(
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
                mentionSummaryText: unreadState.hasUnreadMessages ? (remote.mentionSummary?.text ?? "") : "",
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
                conversations,
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

    private func shouldPlayMessageSound(previous: Conversation?, remote: RemoteConversation, mapped: Conversation) -> Bool {
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

}

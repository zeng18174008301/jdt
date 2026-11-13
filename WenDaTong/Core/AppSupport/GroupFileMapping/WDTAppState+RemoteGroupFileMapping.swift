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
        groupModerationStore.cancelMuteBoundaryRefresh(scopeKey: key)
        guard let boundary = group.allMuteNextBoundary,
              let serverTime = group.allMuteServerTime,
              boundary > serverTime else { return }
        let delay = max(0.1, boundary.timeIntervalSince(serverTime))
        let scope = remoteDataScopeKey(for: context)
        let groupID = group.id
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400 * 366) * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            self.groupModerationStore.finishMuteBoundaryRefresh(scopeKey: key)
            await self.refreshGroupBundle(
                groupID: groupID,
                silent: true,
                includeSecondaryData: false,
                queueAfterInFlight: true
            )
        }
        groupModerationStore.installMuteBoundaryRefreshTask(task, scopeKey: key)
    }

    private func prepareRemoteGroupDirectory(_ remoteGroups: [RemoteUserGroup]) {
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
    }

    private func finishRemoteGroupDirectoryProjection() {
        if !shouldShowGroupMemberCount {
            scrubHiddenGroupMemberTotals(scope: remoteDataScopeKey(for: apiContext))
        }
        reapplyAllAvatarRealtimeProjections()
        scheduleRemoteSnapshotCacheWrite(scope: remoteDataScopeKey(for: apiContext))
    }

    func applyRemoteGroups(_ remoteGroups: [RemoteUserGroup]) {
        prepareRemoteGroupDirectory(remoteGroups)
        // Group-only aliases are resolved once, never through every direct peer for every group.
        let aliases = Dictionary(uniqueKeysWithValues: conversationStore.conversationMessageSnapshots().filter { $0.kind == .group }.map {
            ($0.id, remoteChannelID(for: $0))
        })
        let groupChannel: (ConversationMessageSnapshot) -> String = { row in
            row.kind == .group ? aliases[row.id] ?? row.id : ""
        }
        for group in groups {
            ensureGroupConversationExists(group, channelIDForConversation: groupChannel)
            applyGroupHistoryBoundary(group, channelIDForConversation: groupChannel)
            scheduleGroupMuteBoundaryRefresh(for: group, context: apiContext)
        }
        finishRemoteGroupDirectoryProjection()
    }

    func applyRemoteGroupsCooperatively(_ remoteGroups: [RemoteUserGroup], isCurrent: () -> Bool) async {
        guard !Task.isCancelled, isCurrent() else { return }
        prepareRemoteGroupDirectory(remoteGroups)
        // Group-only aliases are resolved once, never through every direct peer for every group.
        let aliases = Dictionary(uniqueKeysWithValues: conversationStore.conversationMessageSnapshots().filter { $0.kind == .group }.map {
            ($0.id, remoteChannelID(for: $0))
        })
        let groupChannel: (ConversationMessageSnapshot) -> String = { row in
            row.kind == .group ? aliases[row.id] ?? row.id : ""
        }
        let directory = groups
        for (index, original) in directory.enumerated() {
            guard !Task.isCancelled, isCurrent() else { return }
            let group = groups.first(where: { $0.id == original.id }) ?? original
            ensureGroupConversationExists(group, channelIDForConversation: groupChannel)
            applyGroupHistoryBoundary(group, channelIDForConversation: groupChannel)
            scheduleGroupMuteBoundaryRefresh(for: group, context: apiContext)
            if index % 8 == 7 { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        guard !Task.isCancelled, isCurrent() else { return }
        finishRemoteGroupDirectoryProjection()
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

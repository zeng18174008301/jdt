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

// MARK: - Group Administration

extension AppState {
    func joinRequests(for groupID: String) -> [GroupJoinRequest] {
        groupJoinRequests[groupID] ?? []
    }

    func loadGroupDetailIfNeeded(groupID: String, force: Bool = false, includeSecondaryData: Bool = true) {
        guard apiContext.hasIMSession else { return }
        if !force,
           group(id: groupID)?.members.isEmpty == false,
           groupAnnouncements[groupID] != nil,
           fileStore.hasGroupFiles(groupID: groupID) {
            return
        }
        Task { await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: includeSecondaryData) }
    }

    func loadNextGroupMembersPageIfNeeded(groupID: String, pageSize: Int = 100) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty,
              apiContext.hasIMSession,
              let group = group(id: normalizedGroupID),
              group.membersPartial else { return }
        let cursor = group.membersNextCursor
        let offset = group.membersNextOffset ?? group.membersLoadedCount
        if let memberCount = group.memberCount,
           memberCount > 0,
           group.membersLoadedCount >= memberCount {
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let profileKey = groupMemberProfileCacheKey(groupID: normalizedGroupID, context: context)
        let profileGenerationAtRequestStart = groupMemberProfileGenerationFloor(groupID: normalizedGroupID)
        let refreshEpoch = groupMemberProfileRefreshEpoch
        let groupRefreshEpoch = groupMemberProfileRefreshEpochByScopedGroupKey[profileKey] ?? 0
        guard context.hasIMSession,
              isCurrentGroupMemberProfileRefresh(
                scope: scope,
                key: profileKey,
                globalEpoch: refreshEpoch,
                groupEpoch: groupRefreshEpoch
              ) else { return }
        let loadingKey = "\(scope)|\(normalizedGroupID)|\(cursor ?? "offset:\(offset)")"
        guard groupMemberPageLoadingKeys.insert(loadingKey).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.groupMemberPageLoadingKeys.remove(loadingKey) }
            do {
                let safeOffset = max(0, offset)
                let members = try await self.api.listGroupMembersPaged(
                    context: context,
                    groupID: normalizedGroupID,
                    limit: min(100, max(20, pageSize)),
                    offset: self.shouldShowGroupMemberCount && cursor == nil ? safeOffset : nil,
                    cursor: cursor,
                    keyword: nil,
                    role: nil
                )
                guard self.isCurrentGroupMemberProfileRefresh(
                    scope: scope,
                    key: profileKey,
                    globalEpoch: refreshEpoch,
                    groupEpoch: groupRefreshEpoch
                ) else { return }
                let didAdvance = members.nextCursor != nil ||
                    (members.nextOffset ?? (members.items.isEmpty ? safeOffset : safeOffset + members.items.count)) > safeOffset
                let loadedCount = max(safeOffset + members.items.count, (self.group(id: normalizedGroupID)?.membersLoadedCount ?? 0) + members.items.count)
                let hasMore = didAdvance && (members.hasMore == true || (members.total ?? 0) > loadedCount)
                self.applyGroupMembers(
                    members.items,
                    selfMember: members.selfMember,
                    total: members.total,
                    groupID: normalizedGroupID,
                    partial: hasMore,
                    nextOffset: hasMore ? (members.nextOffset ?? loadedCount) : nil,
                    nextCursor: hasMore ? members.nextCursor : nil,
                    append: true,
                    profileGenerationAtRequestStart: profileGenerationAtRequestStart
                )
            } catch {
                guard self.isCurrentGroupMemberProfileRefresh(
                    scope: scope,
                    key: profileKey,
                    globalEpoch: refreshEpoch,
                    groupEpoch: groupRefreshEpoch
                ) else { return }
                self.handleRemoteError(error, fallback: "群成员同步失败", silent: true)
            }
        }
    }

    func publishGroupAnnouncement(groupID: String, title: String, content: String, completion: ((Bool) -> Void)? = nil) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, let group = group(id: normalizedGroupID) else {
            toast = "群资料同步中，请稍后再试"
            completion?(false)
            return
        }
        guard requireGroupAdmin(group, action: "发布群公告") else {
            completion?(false)
            return
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            toast = "请输入公告内容"
            completion?(false)
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            completion?(false)
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        Task {
            do {
                let remote = try await api.createGroupAnnouncement(context: context, groupID: normalizedGroupID, title: title, content: trimmedContent)
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                guard !remote.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      remote.groupID.isEmpty || remote.groupID == normalizedGroupID else {
                    toast = "公告返回不完整，请刷新后重试"
                    completion?(false)
                    return
                }
                upsertGroupAnnouncement(
                    groupAnnouncement(
                        from: remote,
                        fallbackGroupID: normalizedGroupID,
                        requestPrivacyEpoch: announcementPrivacyEpoch
                    ),
                    markCurrentRead: false
                )
                toast = "群公告已发布"
                completion?(true)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isCurrentRemoteScope(scope) else { return }
                    await self.refreshGroupBundle(groupID: normalizedGroupID, silent: true, queueAfterInFlight: true)
                }
            } catch {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                handleRemoteError(error, fallback: "群公告发布失败")
                completion?(false)
            }
        }
    }

    func saveGroupAnnouncement(
        groupID: String,
        announcementID: String?,
        expectedUpdatedAt: String?,
        title: String,
        content: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let normalizedAnnouncementID = announcementID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedAnnouncementID.isEmpty else {
            publishGroupAnnouncement(groupID: groupID, title: title, content: content, completion: completion)
            return
        }
        guard let group = group(id: groupID), requireGroupAdmin(group, action: "编辑群公告") else {
            completion?(false)
            return
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = expectedUpdatedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedContent.isEmpty, !revision.isEmpty else {
            toast = revision.isEmpty ? "公告版本不可用，请刷新后重试" : "请输入公告内容"
            completion?(false)
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            completion?(false)
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        Task {
            do {
                let remote = try await api.updateGroupAnnouncement(
                    context: context,
                    groupID: groupID,
                    announcementID: normalizedAnnouncementID,
                    title: trimmedTitle.isEmpty ? "群公告" : trimmedTitle,
                    content: trimmedContent,
                    expectedUpdatedAt: revision
                )
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                let mapped = groupAnnouncement(
                    from: remote,
                    fallbackGroupID: groupID,
                    requestPrivacyEpoch: announcementPrivacyEpoch
                )
                guard mapped.id == normalizedAnnouncementID, mapped.groupID == groupID else {
                    toast = "公告返回不完整，请刷新后重试"
                    completion?(false)
                    return
                }
                upsertGroupAnnouncement(mapped, markCurrentRead: false)
                await refreshGroupAnnouncements(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                toast = "群公告已更新"
                completion?(true)
            } catch IMAPIError.conflict(let code, _) where code == "group_announcement_revision_conflict" {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                await refreshGroupAnnouncements(groupID: groupID, silent: true)
                toast = "公告已被其他管理员更新，请核对后重试"
                completion?(false)
            } catch {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                handleRemoteError(error, fallback: "群公告更新失败")
                completion?(false)
            }
        }
    }

    func isGroupDescriptionMutating(_ groupID: String) -> Bool {
        groupDescriptionMutatingIDs.contains(groupID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func updateGroupDescription(groupID: String, rawValue: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = group(id: normalizedGroupID), canManageGroup(group) else {
            toast = "仅群主或管理员可以修改群描述"
            return false
        }
        let normalizedDescription: String
        do {
            normalizedDescription = try GroupDescriptionInputPolicy.normalize(rawValue)
        } catch let error as GroupDescriptionInputError {
            toast = error.userMessage
            return false
        } catch {
            toast = "群描述格式不正确"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        guard groupDescriptionMutatingIDs.insert(normalizedGroupID).inserted else { return false }
        defer { groupDescriptionMutatingIDs.remove(normalizedGroupID) }
        let scope = remoteDataScopeKey(for: context)
        do {
            let result = try await api.updateGroupDescription(
                context: context,
                groupID: normalizedGroupID,
                description: normalizedDescription,
                expectedGroupRevision: group.groupRevision
            )
            guard isCurrentRemoteScope(scope) else { return false }
            if let index = groups.firstIndex(where: { $0.id == normalizedGroupID }) {
                groups[index].groupDescription = result.settings.groupDescription ?? normalizedDescription
                groups[index].groupRevision = max(groups[index].groupRevision, result.settings.groupRevision)
            }
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope) else { return false }
            toast = normalizedDescription.isEmpty ? "已清除群描述" : "群描述已更新"
            return true
        } catch IMAPIError.conflict(let code, _)
            where code == "group_revision_conflict" || code == "group_revision_required" {
            guard isCurrentRemoteScope(scope) else { return false }
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            toast = "群资料已被其他管理员更新，请核对后重试"
            return false
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "群描述更新失败")
            return false
        }
    }

    func isGroupOwnerTransferMutating(_ groupID: String) -> Bool {
        groupOwnerTransferMutatingIDs.contains(groupID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    func transferGroupOwner(groupID: String, targetUID: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentGroup = group(id: normalizedGroupID),
              currentGroup.isCurrentUserOwner || isGroupOwner(currentUser, in: currentGroup) else {
            toast = "仅当前群主可以转让群主"
            return false
        }
        guard normalizedTargetUID != currentUser.id,
              currentGroup.members.contains(where: { $0.id == normalizedTargetUID && !$0.isCancelledUser }) else {
            toast = "只能转让给当前有效群成员"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        guard groupOwnerTransferMutatingIDs.insert(normalizedGroupID).inserted else { return false }
        defer { groupOwnerTransferMutatingIDs.remove(normalizedGroupID) }
        let scope = remoteDataScopeKey(for: context)
        let idempotencyKey = groupOwnerTransferIdempotencyState.key(
            scope: scope,
            groupID: normalizedGroupID,
            targetUID: normalizedTargetUID
        )
        do {
            let result = try await api.transferGroupOwner(
                context: context,
                groupID: normalizedGroupID,
                newOwnerUID: normalizedTargetUID,
                idempotencyKey: idempotencyKey
            )
            guard isCurrentRemoteScope(scope), result.newOwnerUID == normalizedTargetUID else { return false }
            applyGroupOwnerTransferResult(result, groupID: normalizedGroupID)
            groupOwnerTransferIdempotencyState.clear(
                scope: scope,
                groupID: normalizedGroupID,
                targetUID: normalizedTargetUID
            )
            clearGroupAnnouncementReadCounts(groupID: normalizedGroupID)
            await refreshGroupBundle(
                groupID: normalizedGroupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard isCurrentRemoteScope(scope) else { return false }
            toast = "群主已转让"
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            clearGroupAnnouncementReadCounts(groupID: normalizedGroupID)
            let authorityShowsTransfer = await refreshGroupOwnerTransferAuthority(
                groupID: normalizedGroupID,
                targetUID: normalizedTargetUID,
                context: context,
                scope: scope
            )
            await refreshGroupBundle(
                groupID: normalizedGroupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard isCurrentRemoteScope(scope) else { return false }
            if authorityShowsTransfer {
                groupOwnerTransferIdempotencyState.clear(
                    scope: scope,
                    groupID: normalizedGroupID,
                    targetUID: normalizedTargetUID
                )
                toast = "群主已转让"
                return true
            }
            handleRemoteError(error, fallback: "转让群主失败")
            return false
        }
    }

    private func applyGroupOwnerTransferResult(_ result: RemoteGroupOwnerTransferResult, groupID: String) {
        let existing = group(id: groupID)
        var projected = groupInfo(from: result.group, existing: existing)
        let previousOwnerUID = result.previousOwnerUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let newOwnerUID = result.newOwnerUID.trimmingCharacters(in: .whitespacesAndNewlines)
        projected.ownerID = newOwnerUID

        let previousFallback = existing?.members.first { user($0, matchesIdentifier: previousOwnerUID) }
        let newFallback = existing?.members.first { user($0, matchesIdentifier: newOwnerUID) }
        let previousOwner = result.previousOwner.map { groupMemberUser(from: $0, fallback: previousFallback) }
        let newOwner = result.newOwner.map { groupMemberUser(from: $0, fallback: newFallback) } ?? newFallback
        if let newOwner {
            projected.owner = newOwner.name
        }

        if let previousOwner,
           let index = projected.members.firstIndex(where: { user($0, matchesIdentifier: previousOwnerUID) }) {
            projected.members[index] = previousOwner
        }
        if let newOwner,
           let index = projected.members.firstIndex(where: { user($0, matchesIdentifier: newOwnerUID) }) {
            projected.members[index] = newOwner
        }
        projected.admins.removeAll {
            user($0, matchesIdentifier: previousOwnerUID) || user($0, matchesIdentifier: newOwnerUID)
        }
        if let newOwner {
            projected.admins.append(newOwner)
        }

        if isCurrentUserIdentity(previousOwnerUID) {
            let oldOwnerRole = result.oldOwnerRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            projected.myRole = oldOwnerRole.isEmpty ? "member" : oldOwnerRole
        } else if isCurrentUserIdentity(newOwnerUID) {
            projected.myRole = "owner"
        }
        projected.canManageMuteList = projected.myRole == "owner" || projected.myRole == "admin"

        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index] = projected
        } else {
            groups.append(projected)
        }
        ensureGroupConversationExists(projected)
        reapplyAllAvatarRealtimeProjections()
    }

    private func refreshGroupOwnerTransferAuthority(
        groupID: String,
        targetUID: String,
        context: IMAPIContext,
        scope: String
    ) async -> Bool {
        let profileGeneration = groupMemberProfileGenerationFloor(groupID: groupID)
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        do {
            let summary = try await groupSummaryWithLegacyFallback(context: context, groupID: groupID)
            guard isCurrentRemoteScope(scope) else { return false }
            await updateGroupSummary(
                groupID,
                from: summary,
                profileGenerationAtRequestStart: profileGeneration,
                announcementPrivacyEpochAtRequestStart: announcementPrivacyEpoch
            )
            return group(id: groupID)?.ownerID == targetUID
        } catch {
            return false
        }
    }

    func approveGroupJoinRequest(groupID: String, requestID: String) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                let remote = try await api.reviewGroupJoinRequest(context: context, groupID: groupID, requestID: requestID, approved: true)
                guard isCurrentRemoteScope(scope) else { return }
                upsertGroupJoinRequest(groupID: groupID, request: groupJoinRequest(from: remote))
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                toast = "已同意入群申请"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "入群申请审批失败")
            }
        }
    }

    func rejectGroupJoinRequest(groupID: String, requestID: String) {
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                let remote = try await api.reviewGroupJoinRequest(context: context, groupID: groupID, requestID: requestID, approved: false)
                guard isCurrentRemoteScope(scope) else { return }
                upsertGroupJoinRequest(groupID: groupID, request: groupJoinRequest(from: remote))
                toast = "已拒绝入群申请"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "入群申请处理失败")
            }
        }
    }

    func isGroupOwner(_ user: IMUser, in group: GroupInfo) -> Bool {
        if !group.ownerID.isEmpty {
            return [user.id, user.userID, user.username].contains {
                !$0.isEmpty && $0 == group.ownerID
            }
        }
        return user.name == group.owner || (group.owner == currentUser.name && user.id == currentUser.id)
    }

    func isGroupAdmin(_ user: IMUser, in group: GroupInfo) -> Bool {
        isGroupOwner(user, in: group) || group.admins.contains { admin in
            [user.id, user.userID, user.username].contains { candidate in
                !candidate.isEmpty && [admin.id, admin.userID, admin.username].contains(candidate)
            }
        }
    }

    func canManageGroup(_ group: GroupInfo) -> Bool {
        group.canCurrentUserManage || isGroupOwner(currentUser, in: group) || group.admins.contains { admin in
            [admin.id, admin.userID, admin.username].contains { isCurrentUserIdentity($0) }
        }
    }

    func canCurrentUserSend(in group: GroupInfo, at _: Date = Date()) -> Bool {
        if group.groupMuted && !canManageGroup(group) {
            return false
        }
        if group.allMuteRepairRequired && group.allMuted && !canManageGroup(group) {
            return false
        }
        if let active = group.allMuteActive {
            return !active || canManageGroup(group)
        }
        return !group.allMuted || canManageGroup(group)
    }

    func canManageGroupMuteList(_ group: GroupInfo) -> Bool {
        group.canManageMuteList || canManageGroup(group)
    }

    func groupMuteListItems(for groupID: String) -> [GroupMuteListItem] {
        let resolved = resolvedAvatarRealtimeProjectionMap()
        return (groupMuteListItemsByGroupID[
            groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        ] ?? []).map { item in
            guard let projection = resolved[item.targetUID] else { return item }
            return AvatarRealtimeSurfaceProjector.groupMuteListItem(
                item,
                projection: projection.value,
                resolvedURL: projection.url
            )
        }
    }

    func groupMuteListErrorMessage(for groupID: String) -> String? {
        groupMuteListErrorMessages[groupID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func isGroupMuteListLoading(groupID: String) -> Bool {
        groupMuteListLoadingIDs.contains(groupID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func isGroupMuteListMutating(groupID: String, targetUID: String) -> Bool {
        groupMuteListMutatingKeys.contains(groupMuteListMutationKey(groupID: groupID, targetUID: targetUID))
    }

    func groupMuteListCandidateMembers(for groupID: String) -> [IMUser] {
        guard let group = group(id: groupID) else { return [] }
        let mutedIDs = Set(groupMuteListItems(for: groupID).flatMap { item in
            [item.targetUID, item.targetUserID, item.targetUsername]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        })
        let currentIDs = currentUserIdentitySet()
        var seen: Set<String> = []
        return group.members
            .filter { user in
                let keys = userIdentityKeys(user)
                guard !keys.isEmpty else { return false }
                guard keys.isDisjoint(with: currentIDs) else { return false }
                guard keys.isDisjoint(with: mutedIDs) else { return false }
                guard !isGroupOwner(user, in: group), !isGroupAdmin(user, in: group), !user.isCancelledUser else { return false }
                let key = keys.sorted().first ?? ""
                return !key.isEmpty && seen.insert(key).inserted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadGroupMuteList(groupID: String, force: Bool = false) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else { return }
        guard let group = group(id: normalizedGroupID), canManageGroupMuteList(group) else {
            toast = "禁言名单仅群主或管理员可查看"
            return
        }
        guard force || groupMuteListItemsByGroupID[normalizedGroupID] == nil else { return }
        guard !groupMuteListLoadingIDs.contains(normalizedGroupID) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        groupMuteListLoadingIDs.insert(normalizedGroupID)
        groupMuteListErrorMessages[normalizedGroupID] = nil
        Task {
            defer {
                if isCurrentRemoteScope(scope) {
                    groupMuteListLoadingIDs.remove(normalizedGroupID)
                }
            }
            do {
                let remoteItems = try await api.listGroupMuteList(context: context, groupID: normalizedGroupID)
                guard isCurrentRemoteScope(scope) else { return }
                let mapped = remoteItems.map { groupMuteListItem(from: $0) }
                groupMuteListItemsByGroupID[normalizedGroupID] = mapped
                updateGroupMuteListCount(groupID: normalizedGroupID, count: mapped.count)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                let message = userFacingError(error)
                groupMuteListErrorMessages[normalizedGroupID] = message
                handleRemoteError(error, fallback: "禁言名单同步失败")
            }
        }
    }

    @discardableResult
    func addGroupMuteListMember(groupID: String, targetUID: String, reason: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, !normalizedTargetUID.isEmpty else {
            toast = "请选择要禁言的成员"
            return false
        }
        guard let group = group(id: normalizedGroupID), canManageGroupMuteList(group) else {
            toast = "禁言名单仅群主或管理员可操作"
            return false
        }
        let fallbackTarget = group.members.first(where: { userIdentityKeys($0).contains(normalizedTargetUID) })
        if let target = fallbackTarget,
           isGroupOwner(target, in: group) || isGroupAdmin(target, in: group) {
            toast = "群主或管理员不能加入禁言名单"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let mutationKey = groupMuteListMutationKey(groupID: normalizedGroupID, targetUID: normalizedTargetUID)
        guard groupMuteListMutatingKeys.insert(mutationKey).inserted else { return false }
        defer { groupMuteListMutatingKeys.remove(mutationKey) }
        do {
            let remote = try await api.addGroupMuteListMember(
                context: context,
                groupID: normalizedGroupID,
                targetUID: normalizedTargetUID,
                reason: reason
            )
            guard isCurrentRemoteScope(scope) else { return false }
            upsertGroupMuteListItem(groupMuteListItem(
                from: remote,
                fallbackGroupID: normalizedGroupID,
                fallbackTarget: fallbackTarget,
                fallbackTargetUID: normalizedTargetUID,
                fallbackReason: reason
            ))
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope) else { return false }
            toast = "已加入禁言名单"
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "添加禁言成员失败")
            return false
        }
    }

    @discardableResult
    func removeGroupMuteListMember(groupID: String, targetUID: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, !normalizedTargetUID.isEmpty else { return false }
        guard let group = group(id: normalizedGroupID), canManageGroupMuteList(group) else {
            toast = "禁言名单仅群主或管理员可操作"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        let mutationKey = groupMuteListMutationKey(groupID: normalizedGroupID, targetUID: normalizedTargetUID)
        guard groupMuteListMutatingKeys.insert(mutationKey).inserted else { return false }
        defer { groupMuteListMutatingKeys.remove(mutationKey) }
        do {
            try await api.removeGroupMuteListMember(context: context, groupID: normalizedGroupID, uid: normalizedTargetUID)
            guard isCurrentRemoteScope(scope) else { return false }
            removeLocalGroupMuteListItem(groupID: normalizedGroupID, targetUID: normalizedTargetUID)
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope) else { return false }
            toast = "已解除成员禁言"
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "解除禁言失败")
            return false
        }
    }

    private func groupMuteListMutationKey(groupID: String, targetUID: String) -> String {
        [
            groupID.trimmingCharacters(in: .whitespacesAndNewlines),
            targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .joined(separator: "|")
    }

    private func userIdentityKeys(_ user: IMUser) -> Set<String> {
        Set([user.id, user.userID, user.username]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    func groupMuteListItem(
        from remote: RemoteGroupMuteListItem,
        fallbackGroupID: String = "",
        fallbackTarget: IMUser? = nil,
        fallbackTargetUID: String = "",
        fallbackReason: String = ""
    ) -> GroupMuteListItem {
        func firstNonempty(_ values: [String]) -> String {
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        }

        let groupID = firstNonempty([remote.groupID, fallbackGroupID])
        let targetUID = firstNonempty([remote.targetUID, fallbackTarget?.id ?? "", fallbackTargetUID])
        let targetUserID = firstNonempty([remote.targetUserID, fallbackTarget?.userID ?? "", targetUID])
        let targetUsername = firstNonempty([remote.targetUsername, fallbackTarget?.username ?? ""])
        let targetNickname = firstNonempty([remote.targetNickname, fallbackTarget?.name ?? ""])
        let rawAvatarURL = firstNonempty([remote.targetAvatar, fallbackTarget?.avatarURL ?? ""])
        let avatarURL = rawAvatarURL.isEmpty ? "" : resolveTenantAssetURL(rawAvatarURL)
        let resolvedReason = firstNonempty([remote.reason, fallbackReason])
        return GroupMuteListItem(
            groupID: groupID,
            targetUID: targetUID,
            targetUserID: targetUserID,
            targetUsername: targetUsername,
            targetNickname: targetNickname,
            targetAvatarURL: avatarURL,
            targetRole: remote.targetRole,
            operatorUID: remote.operatorUID,
            operatorName: remote.operatorName,
            reason: resolvedReason,
            createdAt: remote.createdAt ?? "",
            updatedAt: remote.updatedAt ?? "",
            createdAtText: displayTime(remote.createdAt),
            updatedAtText: displayTime(remote.updatedAt)
        )
    }

    private func upsertGroupMuteListItem(_ item: GroupMuteListItem) {
        let groupID = item.groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupID.isEmpty else { return }
        var items = groupMuteListItemsByGroupID[groupID] ?? []
        let targetKeys = Set([item.targetUID, item.targetUserID, item.targetUsername]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        if let index = items.firstIndex(where: { existing in
            let existingKeys = Set([existing.targetUID, existing.targetUserID, existing.targetUsername]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
            return !existingKeys.isDisjoint(with: targetKeys)
        }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        groupMuteListItemsByGroupID[groupID] = items
        updateGroupMuteListCount(groupID: groupID, count: items.count)
    }

    private func removeLocalGroupMuteListItem(groupID: String, targetUID: String) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, !normalizedTargetUID.isEmpty else { return }
        var items = groupMuteListItemsByGroupID[normalizedGroupID] ?? []
        items.removeAll { item in
            [item.targetUID, item.targetUserID, item.targetUsername]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains(normalizedTargetUID)
        }
        groupMuteListItemsByGroupID[normalizedGroupID] = items
        updateGroupMuteListCount(groupID: normalizedGroupID, count: items.count)
    }

    private func updateGroupMuteListCount(groupID: String, count: Int) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].muteListCount = count
    }

    func requireGroupAdmin(_ group: GroupInfo, action: String) -> Bool {
        guard canManageGroup(group) else {
            toast = "\(action) 仅群主或管理员可操作"
            return false
        }
        return true
    }

    func inviteCandidates(for group: GroupInfo) -> [IMUser] {
        let existingIDs = Set(group.members.map(\.id))
        var seen: Set<String> = []
        var source = contacts
        if canManageGroup(group) {
            let knownTenantUsers = groups.flatMap(\.members)
            source.append(contentsOf: knownTenantUsers)
        }
        return source
            .filter { user in
                user.id != currentUser.id && !existingIDs.contains(user.id) && seen.insert(user.id).inserted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createGroup(name: String, memberIDs: [String]) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = "请输入群名称"
            return nil
        }
        guard canCreateGroupChat else {
            toast = "管理员已关闭成员建群"
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        let memberUIDs = normalizedGroupMemberUIDs(from: memberIDs)

        do {
            let response = try await api.createGroup(context: context, name: trimmed, memberUIDs: memberUIDs)
            guard isCurrentRemoteScope(scope) else { return nil }
            let groupID = response.group.groupID
            let groupName = response.group.name.isEmpty ? trimmed : response.group.name
            if !groupID.isEmpty {
                upsertCreatedGroupConversation(groupID: groupID, name: groupName, memberIDs: memberUIDs)
            }
            applyImmediateSystemMessages(response.systemMessages)
            let conversationID = createdGroupConversationID(groupID: groupID, groupName: groupName)
            scheduleCreatedGroupPostflight(groupID: groupID, scope: scope)
            toast = memberUIDs.isEmpty ? "已创建群聊" : "已创建群聊，成员正在同步"
            return conversationID
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            handleRemoteError(error, fallback: "创建群聊失败")
            return nil
        }
    }

    private func normalizedGroupMemberUIDs(from memberIDs: [String]) -> [String] {
        let currentIDs = currentUserIdentitySet()
        var seen: Set<String> = []
        return memberIDs.compactMap { rawID in
            let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { return nil }
            let resolvedID = user(for: trimmedID)?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedID
            guard !resolvedID.isEmpty, !currentIDs.contains(resolvedID), seen.insert(resolvedID).inserted else {
                return nil
            }
            return resolvedID
        }
    }

    private func scheduleCreatedGroupPostflight(groupID: String, scope: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.refreshRemoteSnapshot(silent: true, force: true)
            guard self.isCurrentRemoteScope(scope), !groupID.isEmpty else { return }
            await self.refreshGroupBundle(groupID: groupID, silent: true)
            guard self.isCurrentRemoteScope(scope) else { return }
            self.syncConversationMessagesIfNeeded(groupID, force: true)
        }
    }

    private func createdGroupConversationID(groupID: String, groupName: String) -> String? {
        if let conversation = conversations.first(where: { conversation in
            conversation.kind == .group && (conversation.id == groupID || remoteChannelID(for: conversation) == groupID || conversation.title == groupName)
        }) {
            return conversation.id
        }
        if !groupID.isEmpty { return groupID }
        return groups.first(where: { $0.name == groupName })?.id
    }

    private func upsertCreatedGroupConversation(groupID: String, name: String, memberIDs: [String]) {
        var seenMemberIDs = Set<String>()
        let members = ([currentUser] + memberIDs.compactMap { user(for: $0) }).filter { user in
            seenMemberIDs.insert(user.id).inserted
        }
        conversationStore.upsertCreatedGroupConversation(
            groupID: groupID,
            name: name,
            members: members,
            invitedMemberCount: memberIDs.count,
            accentHex: stableSeed(groupID),
            channelIDForConversation: { self.remoteChannelID(for: $0) }
        )
        if !shouldShowGroupMemberCount {
            conversationStore.scrubGroupMemberTotals()
        }
    }

    @discardableResult
    func requestJoinGroup(groupID: String, reason: String = "") async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else {
            toast = "群聊不存在或已删除"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)

        do {
            let response = try await api.createGroupJoinRequest(context: context, groupID: normalizedGroupID, reason: reason)
            guard isCurrentRemoteScope(scope) else { return false }
            applyImmediateSystemMessages(response.systemMessages)
            mergeInboxNotifications(response.notifications)
            await refreshInboxSilently()
            guard isCurrentRemoteScope(scope) else { return false }
            if response.requiresApproval {
                toast = "已提交入群申请，等待群主或管理员审核"
            } else {
                await refreshGroupBundle(groupID: normalizedGroupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return false }
                syncConversationMessagesIfNeeded(normalizedGroupID, force: true)
                toast = "已加入群聊"
            }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "申请入群失败")
            return false
        }
    }

    @discardableResult
    func inviteGroupMembers(groupID: String, memberIDs: [String]) async -> Bool {
        let uniqueIDs = Array(Set(memberIDs)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !uniqueIDs.isEmpty else {
            toast = "请选择要邀请的成员"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)

        do {
            let response = try await api.inviteGroupMembers(context: context, groupID: groupID, memberUIDs: uniqueIDs)
            guard isCurrentRemoteScope(scope) else { return false }
            applyImmediateSystemMessages(response.systemMessages)
            mergeInboxNotifications(response.notifications)
            await refreshGroupBundle(groupID: groupID, silent: true)
            guard isCurrentRemoteScope(scope) else { return false }
            await refreshInboxSilently()
            guard isCurrentRemoteScope(scope) else { return false }
            if response.requiresApproval {
                toast = "已提交入群邀请，等待群主或管理员审核"
            } else {
                syncConversationMessagesIfNeeded(groupID, force: true)
                toast = "已邀请 \(max(response.items.count, uniqueIDs.count)) 人入群"
            }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "邀请入群失败")
            return false
        }
    }

    func toggleGroupMuted(_ groupID: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        groups[groupIndex].muted.toggle()
        let isMuted = groups[groupIndex].muted
        conversationStore.setGroupConversationMuted(
            groupID: groupID,
            groupName: groups[groupIndex].name,
            isMuted: isMuted
        )
        toast = isMuted ? "已开启群免打扰" : "已关闭群免打扰"
        Task {
            do {
                let result = try await api.updateGroupDND(context: context, groupID: groupID, muted: isMuted)
                guard isCurrentRemoteScope(scope) else { return }
                await updateGroupDetail(groupID, from: result)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "群免打扰设置失败")
            }
        }
    }

    func toggleGroupAllMuted(_ groupID: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let mode: GroupMuteMode = groups[groupIndex].allMuted ? .off : .always
        configureGroupMute(groupID, mode: mode)
    }

    func configureGroupAllMuted(_ groupID: String, enabled: Bool, startAt: Date, endAt: Date) {
        configureGroupMute(
            groupID,
            mode: enabled ? .scheduled : .off,
            startAt: enabled ? startAt : nil,
            endAt: enabled ? endAt : nil
        )
    }

    func isGroupMuteMutating(_ groupID: String) -> Bool {
        groupMuteMutatingIDs.contains(groupID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func groupMuteErrorMessage(for groupID: String) -> String? {
        groupMuteErrorMessages[groupID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    @discardableResult
    func configureGroupMute(
        _ groupID: String,
        mode: GroupMuteMode,
        startAt: Date? = nil,
        endAt: Date? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            completion?(false)
            return false
        }
        guard canManageGroup(groups[groupIndex]) else {
            toast = "全员禁言仅群主或管理员可操作"
            completion?(false)
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            completion?(false)
            return false
        }
        let normalizedState: GroupMuteModeState
        do {
            normalizedState = try GroupMuteModeState.normalize(
                GroupMuteModeIntent(
                    allMuted: mode != .off,
                    mode: mode,
                    startAt: startAt,
                    endAt: endAt
                )
            )
        } catch let error as GroupMuteModeValidationError {
            toast = error == .invalidWindow ? "固定时段需提供有效的开始和结束时间" : "全员禁言设置不合法"
            completion?(false)
            return false
        } catch {
            toast = "全员禁言设置不合法"
            completion?(false)
            return false
        }

        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = remoteDataScopeKey(for: context)
        let mutationKey = groupMuteScopeKey(groupID: normalizedGroupID, context: context)
        let previous = groups[groupIndex]
        groupMuteMutationSequence &+= 1
        let token = groupMuteMutationSequence
        groupMuteMutationTokensByScope[mutationKey] = token
        groupMuteMutatingIDs.insert(normalizedGroupID)
        groupMuteErrorMessages[normalizedGroupID] = nil

        Task {
            do {
                let result = try await api.updateGroupMute(
                    context: context,
                    groupID: normalizedGroupID,
                    mode: normalizedState.mode,
                    startAt: normalizedState.startAt,
                    endAt: normalizedState.endAt,
                    expectedGroupRevision: previous.groupRevision
                )
                guard isCurrentRemoteScope(scope),
                      groupMuteMutationTokensByScope[mutationKey] == token else { return }
                let existing = group(id: normalizedGroupID)
                let mapped = groupInfo(from: result.summary, detail: result, existing: existing)
                guard groupMuteMutationTokensByScope[mutationKey] == token else { return }
                if let index = groups.firstIndex(where: { $0.id == normalizedGroupID }) {
                    groups[index] = mapped
                } else {
                    groups.append(mapped)
                }
                ensureGroupConversationExists(mapped)
                applyGroupHistoryBoundary(mapped)
                scheduleGroupMuteBoundaryRefresh(for: mapped, context: context)
                if !shouldShowGroupMemberCount {
                    scrubHiddenGroupMemberTotals(scope: scope)
                }
                groupMuteMutationTokensByScope[mutationKey] = nil
                groupMuteMutatingIDs.remove(normalizedGroupID)
                groupMuteErrorMessages[normalizedGroupID] = nil

                let confirmed = mapped
                let previewMessage: String
                switch normalizedState.mode {
                case .off:
                    previewMessage = "群主已关闭全员禁言"
                    toast = "已关闭全员禁言"
                case .always:
                    previewMessage = "群主已开启一直禁言"
                    toast = "一直禁言已立即生效"
                case .scheduled:
                    previewMessage = "群主已设置固定时段禁言 \(confirmed.allMuteTimeRangeText())"
                    toast = "已保存固定时段 \(confirmed.allMuteTimeRangeText())"
                }
                conversationStore.updateGroupAllMutedConversationPreview(
                    groupID: confirmed.id,
                    groupName: confirmed.name,
                    message: previewMessage
                ) { [self] conversation in
                    remoteChannelID(for: conversation)
                }
                completion?(true)
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope),
                      groupMuteMutationTokensByScope[mutationKey] == token else { return }
                groupMuteMutationTokensByScope[mutationKey] = nil
                groupMuteMutatingIDs.remove(normalizedGroupID)
                await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
                toast = "群设置已被其他管理员更新，请核对后重试"
                groupMuteErrorMessages[normalizedGroupID] = toast
                completion?(false)
            } catch {
                guard isCurrentRemoteScope(scope),
                      groupMuteMutationTokensByScope[mutationKey] == token else { return }
                groupMuteMutationTokensByScope[mutationKey] = nil
                groupMuteMutatingIDs.remove(normalizedGroupID)
                if let currentIndex = groups.firstIndex(where: { $0.id == normalizedGroupID }) {
                    groups[currentIndex] = previous
                    scheduleGroupMuteBoundaryRefresh(for: previous, context: context)
                }
                handleRemoteError(error, fallback: "全员禁言设置失败")
                groupMuteErrorMessages[normalizedGroupID] = toast ?? "全员禁言设置失败"
                completion?(false)
            }
        }
        return true
    }

    func toggleGroupInviteApproval(_ groupID: String, enabled: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard canManageGroup(groups[groupIndex]) else {
            toast = "入群审批仅群主或管理员可操作"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let expectedGroupRevision = groups[groupIndex].groupRevision
        Task {
            do {
                let result = try await api.updateGroupInviteApproval(
                    context: context,
                    groupID: groupID,
                    required: enabled,
                    expectedGroupRevision: expectedGroupRevision
                )
                guard isCurrentRemoteScope(scope) else { return }
                await updateGroupDetail(groupID, from: result)
                toast = enabled ? "已开启入群审批" : "已关闭入群审批"
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
                toast = "群设置已被其他管理员更新，请核对后重试"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "入群审批设置失败")
            }
        }
    }

    func toggleGroupHistoryVisibility(_ groupID: String, enabled: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard canManageGroup(groups[groupIndex]) else {
            toast = "仅群主或管理员可以修改历史消息可见范围"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let expectedGroupRevision = groups[groupIndex].groupRevision
        #if DEBUG
        if groupHistoryVisibilityScreenshotScenario != nil {
            groups[groupIndex].historyVisible = enabled
            return
        }
        #endif
        Task {
            do {
                let result = try await api.updateGroupHistoryVisibility(
                    context: context,
                    groupID: groupID,
                    historyVisible: enabled,
                    expectedGroupRevision: expectedGroupRevision
                )
                guard isCurrentRemoteScope(scope) else { return }
                await updateGroupDetail(groupID, from: result)
                toast = enabled ? "已设置新成员可查看入群前消息" : "已设置新成员仅可查看入群后消息"
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
                toast = "群设置已被其他管理员更新，请核对后重试"
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "历史消息可见范围设置失败")
            }
        }
    }

    func setGroupMemberAdmin(groupID: String, userID: String, isAdmin: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let user = groups[groupIndex].members.first(where: { $0.id == userID }) else { return }

        guard groups[groupIndex].isCurrentUserOwner || isGroupOwner(currentUser, in: groups[groupIndex]) else {
            toast = "仅群主可以调整管理员"
            return
        }

        if isGroupOwner(user, in: groups[groupIndex]) {
            toast = "群主身份不可调整"
            return
        }

        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let isAlreadyAdmin = groups[groupIndex].admins.contains { $0.id == userID }
        if isAdmin, !isAlreadyAdmin {
            groups[groupIndex].admins.append(user)
            toast = "已将 \(user.name) 设为管理员"
        } else if !isAdmin, isAlreadyAdmin {
            groups[groupIndex].admins.removeAll { $0.id == userID }
            toast = "已取消 \(user.name) 的管理员身份"
        }
        Task {
            do {
                _ = try await api.updateGroupMemberRole(context: context, groupID: groupID, userID: userID, role: isAdmin ? "admin" : "member")
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "管理员设置失败")
            }
        }
    }

    func removeGroupMember(groupID: String, userID: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let user = groups[groupIndex].members.first(where: { $0.id == userID }) else { return }

        guard canManageGroup(groups[groupIndex]) else {
            toast = "移除成员仅群主或管理员可操作"
            return
        }

        if isGroupOwner(user, in: groups[groupIndex]) {
            toast = "不能移出群主"
            return
        }

        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let groupName = groups[groupIndex].name
        groups[groupIndex].members.removeAll { $0.id == userID }
        groups[groupIndex].admins.removeAll { $0.id == userID }
        if shouldShowGroupMemberCount {
            groups[groupIndex].memberCount = (groups[groupIndex].memberCount ?? 0) > 0
                ? max(0, (groups[groupIndex].memberCount ?? 0) - 1)
                : groups[groupIndex].members.count
        } else {
            groups[groupIndex].memberCount = nil
        }
        conversationStore.removeParticipantFromGroupConversation(
            groupID: groupID,
            groupName: groupName,
            userID: userID,
            memberCount: shouldShowGroupMemberCount ? groups[groupIndex].effectiveMemberCount : nil
        )
        if !shouldShowGroupMemberCount {
            conversationStore.scrubGroupMemberTotals()
        }
        toast = "已将 \(user.name) 移出群聊"
        Task {
            do {
                let response = try await api.removeGroupMember(context: context, groupID: groupID, userID: userID)
                guard isCurrentRemoteScope(scope) else { return }
                applySearchInvalidations(response.searchInvalidations)
                await refreshGroupBundle(groupID: groupID, silent: true)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "移出成员失败")
            }
        }
    }

    @discardableResult
    func leaveGroup(groupID: String) async -> Bool {
        guard let group = group(id: groupID) else {
            toast = "该群聊不存在或已解散"
            removeGroupLifecycleLocalState(groupID: groupID, reason: "leave_missing_group")
            return false
        }
        guard !group.isCurrentUserOwner && !isGroupOwner(currentUser, in: group) else {
            toast = "群主需先转让群主或解散该群"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let response = try await api.leaveGroup(context: context, groupID: groupID, reason: "user_request")
            guard isCurrentRemoteScope(scope) else { return false }
            // 成功口径:HTTP 200 且 left == true。通知侧字段
            // (notification_status/notification_failed)不参与成败判定,
            // 通知失败不影响退群本身。
            guard response.left else {
                toast = "退出群聊失败，请稍后重试"
                return false
            }
            applySearchInvalidations(response.searchInvalidations)
            removeGroupLifecycleLocalState(groupID: response.groupID.isEmpty ? groupID : response.groupID, reason: "group_left")
            toast = "已退出群聊"
            conversationListReturnToken += 1
            // 快照刷新放后台,不阻塞界面立即关闭弹窗返回会话列表。
            Task { _ = await refreshRemoteSnapshot(silent: true, force: true) }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "退出群聊失败")
            return false
        }
    }

    func previewDissolveGroup(groupID: String) async -> RemoteGroupDissolvePreview? {
        guard let group = group(id: groupID) else {
            toast = "该群聊不存在或已解散"
            removeGroupLifecycleLocalState(groupID: groupID, reason: "dissolve_preview_missing_group")
            return nil
        }
        guard group.isCurrentUserOwner || isGroupOwner(currentUser, in: group) else {
            toast = "只有群主可以解散该群"
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let preview = try await api.previewDissolveGroup(context: context, groupID: groupID)
            guard isCurrentRemoteScope(scope) else { return nil }
            return preview
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            handleRemoteError(error, fallback: "解散预览失败")
            return nil
        }
    }

    @discardableResult
    func dissolveGroup(groupID: String) async -> Bool {
        guard let group = group(id: groupID) else {
            toast = "该群聊不存在或已解散"
            removeGroupLifecycleLocalState(groupID: groupID, reason: "dissolve_missing_group")
            return false
        }
        guard group.isCurrentUserOwner || isGroupOwner(currentUser, in: group) else {
            toast = "只有群主可以解散该群"
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let response = try await api.dissolveGroup(
                context: context,
                groupID: groupID,
                confirmed: true,
                reason: "owner_request"
            )
            guard isCurrentRemoteScope(scope) else { return false }
            // 成功口径:HTTP 200 且 dissolved == true。通知侧字段失败不影响解散本身。
            guard response.dissolved else {
                toast = "解散该群失败，请稍后重试"
                return false
            }
            applySearchInvalidations(response.searchInvalidations)
            removeGroupLifecycleLocalState(groupID: response.groupID.isEmpty ? groupID : response.groupID, reason: "group_dissolved")
            toast = "群聊已解散"
            conversationListReturnToken += 1
            // 快照刷新放后台,不阻塞界面立即关闭弹窗返回会话列表。
            Task { _ = await refreshRemoteSnapshot(silent: true, force: true) }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            handleRemoteError(error, fallback: "解散该群失败")
            return false
        }
    }

    func applyGroupLifecycleEventForTesting(event: String, groupID: String) {
        applyGroupLifecycleEvent(event: event, groupID: groupID)
    }

    func applyGroupLifecycleEvent(event: String, groupID: String) {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !groupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if normalizedEvent == "group_left" || normalizedEvent == "group_dissolved" {
            removeGroupLifecycleLocalState(groupID: groupID, reason: normalizedEvent)
            if normalizedEvent == "group_dissolved" {
                toast = "群聊已解散"
            }
        }
        if normalizedEvent == "group_member_left" {
            Task { await refreshInboxSilently() }
        }
    }

    private func removeGroupLifecycleLocalState(groupID: String, reason: String) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty else { return }
        let profileKey = groupMemberProfileCacheKey(groupID: normalizedGroupID)
        groupMemberProfileRefreshEpochByScopedGroupKey[profileKey, default: 0] &+= 1
        myGroupNicknamesByScopedGroupKey.removeValue(forKey: profileKey)
        myGroupMemberProjectionsByScopedGroupKey.removeValue(forKey: profileKey)
        groupMemberProfileGenerationByScopedGroupKey.removeValue(forKey: profileKey)
        minimumGroupMemberProfileGenerationByScopedGroupKey.removeValue(forKey: profileKey)
        groupMemberProfileRefreshTasks.removeValue(forKey: profileKey)?.cancel()
        groups.removeAll { $0.id == normalizedGroupID }
        groupAnnouncements[normalizedGroupID] = nil
        currentGroupAnnouncements[normalizedGroupID] = nil
        groupJoinRequests[normalizedGroupID] = nil
        fileStore.clearGroupFiles(groupID: normalizedGroupID)

        let matchingConversationIDs = conversations
            .filter { conversation in
                conversation.kind == .group && (conversation.id == normalizedGroupID || remoteChannelID(for: conversation) == normalizedGroupID)
            }
            .map(\.id)
        for conversationID in matchingConversationIDs {
            if let conversation = conversations.first(where: { $0.id == conversationID }) {
                for message in conversation.messages {
                    invalidateIndexedMediaCache(for: message, state: .authorizationStale)
                }
            }
            leaveRealtimeConversation(conversationID)
            _ = conversationStore.deleteConversation(conversationID: conversationID)
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
        }
        print("[JHT GroupLifecycle] local_removed group=\(Self.shortDebugID(normalizedGroupID)) reason=\(reason) conversations=\(matchingConversationIDs.count)")
    }

}

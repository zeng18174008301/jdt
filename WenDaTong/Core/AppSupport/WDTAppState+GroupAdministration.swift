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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群资料同步中，请稍后再试")
            completion?(false)
            return
        }
        guard requireGroupAdmin(group, action: "发布群公告") else {
            completion?(false)
            return
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入公告内容")
            completion?(false)
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("公告返回不完整，请刷新后重试")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群公告已发布")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(revision.isEmpty ? "公告版本不可用，请刷新后重试" : "请输入公告内容")
            completion?(false)
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("公告返回不完整，请刷新后重试")
                    completion?(false)
                    return
                }
                upsertGroupAnnouncement(mapped, markCurrentRead: false)
                await refreshGroupAnnouncements(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群公告已更新")
                completion?(true)
            } catch IMAPIError.conflict(let code, _) where code == "group_announcement_revision_conflict" {
                guard isCurrentRemoteScope(scope) else {
                    completion?(false)
                    return
                }
                await refreshGroupAnnouncements(groupID: groupID, silent: true)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("公告已被其他管理员更新，请核对后重试")
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

    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_BEGIN
    @discardableResult
    func updateGroupDescription(groupID: String, rawValue: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = group(id: normalizedGroupID), canManageGroup(group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅群主或管理员可以修改群描述")
            return false
        }
        let normalizedDescription: String
        do {
            normalizedDescription = try GroupDescriptionInputPolicy.normalize(rawValue)
        } catch let error as GroupDescriptionInputError {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(error.userMessage)
            return false
        } catch {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群描述格式不正确")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard let operationID = groupModerationStore.beginAdministration(
            .description, groupID: normalizedGroupID
        ) else { return false }
        defer {
            groupModerationStore.finishAdministration(.description, id: operationID, groupID: normalizedGroupID)
        }
        func isCurrentOperation() -> Bool {
            isCurrentRemoteScope(scope)
                && groupModerationStore.ownsAdministration(.description, id: operationID, groupID: normalizedGroupID)
        }
        do {
            let result = try await api.updateGroupDescription(
                context: context,
                groupID: normalizedGroupID,
                description: normalizedDescription,
                expectedGroupRevision: group.groupRevision
            )
            guard isCurrentOperation() else { return false }
            if let index = groups.firstIndex(where: { $0.id == normalizedGroupID }) {
                groups[index].groupDescription = result.settings.groupDescription ?? normalizedDescription
                groups[index].groupRevision = max(groups[index].groupRevision, result.settings.groupRevision)
            }
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentOperation() else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(normalizedDescription.isEmpty ? "已清除群描述" : "群描述已更新")
            return true
        } catch IMAPIError.conflict(let code, _)
            where code == "group_revision_conflict" || code == "group_revision_required" {
            guard isCurrentOperation() else { return false }
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentOperation() else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群资料已被其他管理员更新，请核对后重试")
            return false
        } catch {
            guard isCurrentOperation() else { return false }
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentOperation() else { return false }
            handleRemoteError(error, fallback: "群描述更新失败")
            return false
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_END

    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_BEGIN
    @discardableResult
    func transferGroupOwner(groupID: String, targetUID: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentGroup = group(id: normalizedGroupID),
              currentGroup.isCurrentUserOwner || isGroupOwner(currentUser, in: currentGroup) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅当前群主可以转让群主")
            return false
        }
        guard normalizedTargetUID != currentUser.id,
              currentGroup.members.contains(where: { $0.id == normalizedTargetUID && !$0.isCancelledUser }) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("只能转让给当前有效群成员")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard let operationID = groupModerationStore.beginAdministration(
            .ownerTransfer, groupID: normalizedGroupID
        ) else { return false }
        defer {
            groupModerationStore.finishAdministration(.ownerTransfer, id: operationID, groupID: normalizedGroupID)
        }
        func isCurrentOperation() -> Bool {
            isCurrentRemoteScope(scope)
                && groupModerationStore.ownsAdministration(.ownerTransfer, id: operationID, groupID: normalizedGroupID)
        }
        let idempotencyKey = groupModerationStore.ownerTransferIdempotencyKey(
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
            guard isCurrentOperation(), result.newOwnerUID == normalizedTargetUID else { return false }
            applyGroupOwnerTransferResult(result, groupID: normalizedGroupID)
            groupModerationStore.clearOwnerTransferIdempotencyKey(
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
            guard isCurrentOperation() else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群主已转让")
            return true
        } catch {
            guard isCurrentOperation() else { return false }
            clearGroupAnnouncementReadCounts(groupID: normalizedGroupID)
            let authorityShowsTransfer = await refreshGroupOwnerTransferAuthority(
                groupID: normalizedGroupID,
                targetUID: normalizedTargetUID,
                context: context,
                scope: scope,
                operationID: operationID
            )
            guard isCurrentOperation() else { return false }
            await refreshGroupBundle(
                groupID: normalizedGroupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard isCurrentOperation() else { return false }
            if authorityShowsTransfer {
                groupModerationStore.clearOwnerTransferIdempotencyKey(
                    scope: scope,
                    groupID: normalizedGroupID,
                    targetUID: normalizedTargetUID
                )
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群主已转让")
                return true
            }
            handleRemoteError(error, fallback: "转让群主失败")
            return false
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_END

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

    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_BEGIN
    private func refreshGroupOwnerTransferAuthority(
        groupID: String,
        targetUID: String,
        context: IMAPIContext,
        scope: String,
        operationID: UUID
    ) async -> Bool {
        let profileGeneration = groupMemberProfileGenerationFloor(groupID: groupID)
        let announcementPrivacyEpoch = groupAnnouncementPrivacyEpoch
        do {
            let summary = try await groupSummaryWithLegacyFallback(context: context, groupID: groupID)
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsAdministration(.ownerTransfer, id: operationID, groupID: groupID)
            else { return false }
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
    // WDT_IOS1_REFACTOR_GROUP_ADMINISTRATION_OBSERVATION_20261110_END

    func approveGroupJoinRequest(groupID: String, requestID: String) {
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已同意入群申请")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "入群申请审批失败")
            }
        }
    }

    func rejectGroupJoinRequest(groupID: String, requestID: String) {
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                let remote = try await api.reviewGroupJoinRequest(context: context, groupID: groupID, requestID: requestID, approved: false)
                guard isCurrentRemoteScope(scope) else { return }
                upsertGroupJoinRequest(groupID: groupID, request: groupJoinRequest(from: remote))
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已拒绝入群申请")
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

}

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

extension AppState {
    func canManageGroupMuteList(_ group: GroupInfo) -> Bool {
        group.canManageMuteList || canManageGroup(group)
    }

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    func projectedGroupMuteListItems(_ items: [GroupMuteListItem]) -> [GroupMuteListItem] {
        guard !items.isEmpty else { return items }
        let resolved = resolvedAvatarRealtimeProjectionMap()
        return items.map { item in
            guard let projection = resolved[item.targetUID] else { return item }
            return AvatarRealtimeSurfaceProjector.groupMuteListItem(
                item,
                projection: projection.value,
                resolvedURL: projection.url
            )
        }
    }

    func groupMuteListCandidateMembers(for groupID: String, mutedItems: [GroupMuteListItem]) -> [IMUser] {
        guard let group = group(id: groupID) else { return [] }
        let mutedIDs = Set(mutedItems.flatMap { item in
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("禁言名单仅群主或管理员可查看")
            return
        }
        let snapshot = groupModerationStore.listSnapshot(for: normalizedGroupID)
        guard (force || snapshot.items == nil), !snapshot.isLoading else { return }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let requestID = groupModerationStore.beginListLoad(groupID: normalizedGroupID)
        Task {
            defer { groupModerationStore.finishListLoad(requestID, groupID: normalizedGroupID) }
            do {
                let remoteItems = try await api.listGroupMuteList(context: context, groupID: normalizedGroupID)
                guard isCurrentRemoteScope(scope),
                      groupModerationStore.ownsListLoad(requestID, groupID: normalizedGroupID) else { return }
                let mapped = remoteItems.map { groupMuteListItem(from: $0) }
                groupModerationStore.setListItems(mapped, groupID: normalizedGroupID)
                updateGroupMuteListCount(groupID: normalizedGroupID, count: mapped.count)
            } catch {
                guard isCurrentRemoteScope(scope),
                      groupModerationStore.ownsListLoad(requestID, groupID: normalizedGroupID) else { return }
                let message = userFacingError(error)
                groupModerationStore.setListError(message, groupID: normalizedGroupID)
                handleRemoteError(error, fallback: "禁言名单同步失败")
            }
        }
    }

    @discardableResult
    func addGroupMuteListMember(groupID: String, targetUID: String, reason: String) async -> Bool {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, !normalizedTargetUID.isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请选择要禁言的成员")
            return false
        }
        guard let group = group(id: normalizedGroupID), canManageGroupMuteList(group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("禁言名单仅群主或管理员可操作")
            return false
        }
        let fallbackTarget = group.members.first(where: { userIdentityKeys($0).contains(normalizedTargetUID) })
        if let target = fallbackTarget,
           isGroupOwner(target, in: group) || isGroupAdmin(target, in: group) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群主或管理员不能加入禁言名单")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard let requestID = groupModerationStore.beginMemberMutation(
            groupID: normalizedGroupID, targetUID: normalizedTargetUID
        ) else { return false }
        defer {
            groupModerationStore.finishMemberMutation(
                requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
            )
        }
        do {
            let remote = try await api.addGroupMuteListMember(
                context: context,
                groupID: normalizedGroupID,
                targetUID: normalizedTargetUID,
                reason: reason
            )
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsMemberMutation(
                    requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
                  ) else { return false }
            upsertGroupMuteListItem(groupMuteListItem(
                from: remote,
                fallbackGroupID: normalizedGroupID,
                fallbackTarget: fallbackTarget,
                fallbackTargetUID: normalizedTargetUID,
                fallbackReason: reason
            ))
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsMemberMutation(
                    requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
                  ) else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已加入禁言名单")
            return true
        } catch {
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsMemberMutation(
                    requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
                  ) else { return false }
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("禁言名单仅群主或管理员可操作")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        let scope = remoteDataScopeKey(for: context)
        guard let requestID = groupModerationStore.beginMemberMutation(
            groupID: normalizedGroupID, targetUID: normalizedTargetUID
        ) else { return false }
        defer {
            groupModerationStore.finishMemberMutation(
                requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
            )
        }
        do {
            try await api.removeGroupMuteListMember(context: context, groupID: normalizedGroupID, uid: normalizedTargetUID)
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsMemberMutation(
                    requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
                  ) else { return false }
            removeLocalGroupMuteListItem(groupID: normalizedGroupID, targetUID: normalizedTargetUID)
            await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsMemberMutation(
                    requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
                  ) else { return false }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已解除成员禁言")
            return true
        } catch {
            guard isCurrentRemoteScope(scope),
                  groupModerationStore.ownsMemberMutation(
                    requestID, groupID: normalizedGroupID, targetUID: normalizedTargetUID
                  ) else { return false }
            handleRemoteError(error, fallback: "解除禁言失败")
            return false
        }
    }

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

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

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    private func upsertGroupMuteListItem(_ item: GroupMuteListItem) {
        let groupID = item.groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupID.isEmpty else { return }
        var items = groupModerationStore.listSnapshot(for: groupID).items ?? []
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
        groupModerationStore.setListItems(items, groupID: groupID)
        updateGroupMuteListCount(groupID: groupID, count: items.count)
    }

    private func removeLocalGroupMuteListItem(groupID: String, targetUID: String) {
        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetUID = targetUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroupID.isEmpty, !normalizedTargetUID.isEmpty else { return }
        var items = groupModerationStore.listSnapshot(for: normalizedGroupID).items ?? []
        items.removeAll { item in
            [item.targetUID, item.targetUserID, item.targetUsername]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains(normalizedTargetUID)
        }
        groupModerationStore.setListItems(items, groupID: normalizedGroupID)
        updateGroupMuteListCount(groupID: normalizedGroupID, count: items.count)
    }

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

    private func updateGroupMuteListCount(groupID: String, count: Int) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].muteListCount = count
    }

}

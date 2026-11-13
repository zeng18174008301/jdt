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
    func requireGroupAdmin(_ group: GroupInfo, action: String) -> Bool {
        guard canManageGroup(group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("\(action) 仅群主或管理员可操作")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请输入群名称")
            return nil
        }
        guard canCreateGroupChat else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("管理员已关闭成员建群")
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(memberUIDs.isEmpty ? "已创建群聊" : "已创建群聊，成员正在同步")
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
        if let conversation = conversationStore.conversationMessageSnapshots().first(where: { conversation in
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群聊不存在或已删除")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已提交入群申请，等待群主或管理员审核")
            } else {
                await refreshGroupBundle(groupID: normalizedGroupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return false }
                syncConversationMessagesIfNeeded(normalizedGroupID, force: true)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已加入群聊")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请选择要邀请的成员")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
            if !response.requiresApproval {
                syncConversationMessagesIfNeeded(groupID, force: true)
            }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(response.invitationResultMessage)
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(isMuted ? "已开启群免打扰" : "已关闭群免打扰")
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

    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
    func isGroupMuteMutating(_ groupID: String) -> Bool {
        groupModerationStore.settingsSnapshot(for: groupID.trimmingCharacters(in: .whitespacesAndNewlines)).isMutating
    }

    func groupMuteErrorMessage(for groupID: String) -> String? {
        groupModerationStore.settingsSnapshot(for: groupID.trimmingCharacters(in: .whitespacesAndNewlines)).errorMessage
    }
    // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END

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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("全员禁言仅群主或管理员可操作")
            completion?(false)
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(error == .invalidWindow ? "固定时段需提供有效的开始和结束时间" : "全员禁言设置不合法")
            completion?(false)
            return false
        } catch {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("全员禁言设置不合法")
            completion?(false)
            return false
        }

        let normalizedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = remoteDataScopeKey(for: context)
        let mutationKey = groupMuteScopeKey(groupID: normalizedGroupID, context: context)
        let previous = groups[groupIndex]
        let token = groupModerationStore.beginMuteMutation(scopeKey: mutationKey)
        groupModerationStore.setSettingsMutation(groupID: normalizedGroupID, isMutating: true) // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110

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
                      groupModerationStore.ownsMuteMutation(token, scopeKey: mutationKey) else { return }
                let existing = group(id: normalizedGroupID)
                let mapped = groupInfo(from: result.summary, detail: result, existing: existing)
                guard groupModerationStore.ownsMuteMutation(token, scopeKey: mutationKey) else { return }
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
                groupModerationStore.retireMuteMutation(scopeKey: mutationKey)
                groupModerationStore.setSettingsMutation(groupID: normalizedGroupID, isMutating: false) // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110

                let confirmed = mapped
                let previewMessage: String
                switch normalizedState.mode {
                case .off:
                    previewMessage = "群主已关闭全员禁言"
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已关闭全员禁言")
                case .always:
                    previewMessage = "群主已开启一直禁言"
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("一直禁言已立即生效")
                case .scheduled:
                    previewMessage = "群主已设置固定时段禁言 \(confirmed.allMuteTimeRangeText())"
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已保存固定时段 \(confirmed.allMuteTimeRangeText())")
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
                      groupModerationStore.ownsMuteMutation(token, scopeKey: mutationKey) else { return }
                // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
                groupModerationStore.setSettingsMutation(groupID: normalizedGroupID, isMutating: false)
                await refreshGroupBundle(groupID: normalizedGroupID, silent: true, includeSecondaryData: false)
                guard isCurrentRemoteScope(scope),
                      groupModerationStore.ownsMuteMutation(token, scopeKey: mutationKey) else { return }
                groupModerationStore.retireMuteMutation(scopeKey: mutationKey)
                let message = "群设置已被其他管理员更新，请核对后重试"
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(message)
                groupModerationStore.setSettingsMutation(groupID: normalizedGroupID, isMutating: false, errorMessage: message)
                // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
                completion?(false)
            } catch {
                guard isCurrentRemoteScope(scope),
                      groupModerationStore.ownsMuteMutation(token, scopeKey: mutationKey) else { return }
                groupModerationStore.retireMuteMutation(scopeKey: mutationKey)
                if let currentIndex = groups.firstIndex(where: { $0.id == normalizedGroupID }) {
                    groups[currentIndex] = previous
                    scheduleGroupMuteBoundaryRefresh(for: previous, context: context)
                }
                handleRemoteError(error, fallback: "全员禁言设置失败")
                // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_BEGIN
                groupModerationStore.setSettingsMutation(
                    groupID: normalizedGroupID,
                    isMutating: false,
                    errorMessage: toast ?? "全员禁言设置失败"
                )
                // WDT_IOS1_REFACTOR_GROUP_MODERATION_OBSERVATION_20261110_END
                completion?(false)
            }
        }
        return true
    }

    func toggleGroupInviteApproval(_ groupID: String, enabled: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard canManageGroup(groups[groupIndex]) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("入群审批仅群主或管理员可操作")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(enabled ? "已开启入群审批" : "已关闭入群审批")
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群设置已被其他管理员更新，请核对后重试")
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true)
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: "入群审批设置失败")
            }
        }
    }

    // WDT_APP_CONTRACT_20261021_09: revisioned setting mutation; all other settings are preserved.
    func setGroupMemberFriendApply(groupID: String, enabled: Bool) async -> Bool {
        guard let group = group(id: groupID), canManageGroup(group),
              let client = api as? IMAPIClient, apiContext.hasIMSession else { return false }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let generation = interactionPolicyGeneration
        do {
            let detail = try await client.updateGroupMemberFriendApply(context: context, groupID: groupID,
                enabled: enabled, expectedGroupRevision: group.groupRevision)
            guard isCurrentRemoteScope(scope), interactionPolicyGeneration == generation else { return false }
            await updateGroupDetail(groupID, from: detail)
            return true
        } catch {
            guard isCurrentRemoteScope(scope), interactionPolicyGeneration == generation else { return false }
            await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
            guard isCurrentRemoteScope(scope), interactionPolicyGeneration == generation else { return false }
            if case IMAPIError.conflict(let code, _) = error,
               ["group_revision_conflict", "group_revision_required"].contains(code) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群设置已更新，请核对后重试")
            } else {
                handleRemoteError(error, fallback: "互加好友设置失败")
            }
            return false
        }
    }

    func toggleGroupHistoryVisibility(_ groupID: String, enabled: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard canManageGroup(groups[groupIndex]) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅群主或管理员可以修改历史消息可见范围")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(enabled ? "已设置新成员可查看入群前消息" : "已设置新成员仅可查看入群后消息")
            } catch IMAPIError.conflict(let code, _)
                where code == "group_revision_conflict" || code == "group_revision_required" {
                guard isCurrentRemoteScope(scope) else { return }
                await refreshGroupBundle(groupID: groupID, silent: true, includeSecondaryData: false)
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群设置已被其他管理员更新，请核对后重试")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("仅群主可以调整管理员")
            return
        }

        if isGroupOwner(user, in: groups[groupIndex]) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群主身份不可调整")
            return
        }

        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let isAlreadyAdmin = groups[groupIndex].admins.contains { $0.id == userID }
        if isAdmin, !isAlreadyAdmin {
            groups[groupIndex].admins.append(user)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已将 \(user.name) 设为管理员")
        } else if !isAdmin, isAlreadyAdmin {
            groups[groupIndex].admins.removeAll { $0.id == userID }
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已取消 \(user.name) 的管理员身份")
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

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

// WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_BEGIN
@MainActor
final class ConversationListPresentationStore {
    struct Snapshot: Equatable {
        var showsAnnouncements = true
        var returnToken = 0
        var notificationOpenRequest: IOSNotificationConversationOpenRequest?
    }

    @Published var snapshot = Snapshot()

    func observe<Content: View>(@ViewBuilder content: @escaping (Snapshot) -> Content) -> some View {
        PublisherSnapshotView(initialValue: snapshot, updates: $snapshot.eraseToAnyPublisher(), content: content)
    }
}
// WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110_END

extension AppState {
    func removeGroupMember(groupID: String, userID: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let user = groups[groupIndex].members.first(where: { $0.id == userID }) else { return }

        guard canManageGroup(groups[groupIndex]) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("移除成员仅群主或管理员可操作")
            return
        }

        if isGroupOwner(user, in: groups[groupIndex]) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("不能移出群主")
            return
        }

        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已将 \(user.name) 移出群聊")
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
        guard canLeaveGroupByTenantPolicy else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前企业暂不允许退出群聊")
            return false
        }
        guard let group = group(id: groupID) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该群聊不存在或已解散")
            removeGroupLifecycleLocalState(groupID: groupID, reason: "leave_missing_group")
            return false
        }
        guard !group.isCurrentUserOwner && !isGroupOwner(currentUser, in: group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群主需先转让群主或解散该群")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("退出群聊失败，请稍后重试")
                return false
            }
            applySearchInvalidations(response.searchInvalidations)
            removeGroupLifecycleLocalState(groupID: response.groupID.isEmpty ? groupID : response.groupID, reason: "group_left")
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已退出群聊")
            conversationListPresentationStore.snapshot.returnToken += 1 // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该群聊不存在或已解散")
            removeGroupLifecycleLocalState(groupID: groupID, reason: "dissolve_preview_missing_group")
            return nil
        }
        guard group.isCurrentUserOwner || isGroupOwner(currentUser, in: group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("只有群主可以解散该群")
            return nil
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return nil
        }
        let scope = remoteDataScopeKey(for: context)
        do {
            let preview = try await api.previewDissolveGroup(context: context, groupID: groupID)
            guard isCurrentRemoteScope(scope) else { return nil }
            return preview
        } catch {
            guard isCurrentRemoteScope(scope) else { return nil }
            // WDT_RECEIPT_DETAIL_SCOPE_20261023: preserve the message only in the dissolve context.
            if let message = Self.groupDissolvePermissionMessage(for: error) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("解散预览失败：\(message)")
            } else {
                handleRemoteError(error, fallback: "解散预览失败")
            }
            return nil
        }
    }

    @discardableResult
    func dissolveGroup(groupID: String) async -> Bool {
        guard let group = group(id: groupID) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该群聊不存在或已解散")
            removeGroupLifecycleLocalState(groupID: groupID, reason: "dissolve_missing_group")
            return false
        }
        guard group.isCurrentUserOwner || isGroupOwner(currentUser, in: group) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("只有群主可以解散该群")
            return false
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("解散该群失败，请稍后重试")
                return false
            }
            applySearchInvalidations(response.searchInvalidations)
            removeGroupLifecycleLocalState(groupID: response.groupID.isEmpty ? groupID : response.groupID, reason: "group_dissolved")
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群聊已解散")
            conversationListPresentationStore.snapshot.returnToken += 1 // WDT_IOS1_REFACTOR_CONVERSATION_LIST_NAVIGATION_OBSERVATION_20261110
            // 快照刷新放后台,不阻塞界面立即关闭弹窗返回会话列表。
            Task { _ = await refreshRemoteSnapshot(silent: true, force: true) }
            return true
        } catch {
            guard isCurrentRemoteScope(scope) else { return false }
            // WDT_RECEIPT_DETAIL_SCOPE_20261023
            if let message = Self.groupDissolvePermissionMessage(for: error) {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("解散该群失败：\(message)")
            } else {
                handleRemoteError(error, fallback: "解散该群失败")
            }
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("群聊已解散")
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
        contactStore.groupSelfProfiles.remove(for: profileKey) // WDT_IOS1_REFACTOR_GROUP_SELF_PROFILE_OBSERVATION_20261110
        groupMemberProfileGenerationByScopedGroupKey.removeValue(forKey: profileKey)
        minimumGroupMemberProfileGenerationByScopedGroupKey.removeValue(forKey: profileKey)
        groupMemberProfileRefreshTasks.removeValue(forKey: profileKey)?.cancel()
        groups.removeAll { $0.id == normalizedGroupID }
        groupAnnouncements[normalizedGroupID] = nil
        currentGroupAnnouncements[normalizedGroupID] = nil
        groupJoinRequests[normalizedGroupID] = nil
        fileStore.clearGroupFiles(groupID: normalizedGroupID)

        let matchingConversationIDs = conversationStore.conversationMessageSnapshots()
            .filter { conversation in
                conversation.kind == .group && (conversation.id == normalizedGroupID || remoteChannelID(for: conversation) == normalizedGroupID)
            }
            .map(\.id)
        for conversationID in matchingConversationIDs {
            if let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) {
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

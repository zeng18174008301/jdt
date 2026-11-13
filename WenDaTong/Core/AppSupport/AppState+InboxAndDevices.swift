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
    func reviewGroupInviteApproval(_ approval: GroupInviteApproval, approve: Bool) {
        guard approval.isActionable else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该入群邀请已处理")
            return
        }
        let endpoint = approve ? approval.approveEndpoint : approval.rejectEndpoint
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("审批卡片缺少操作地址，请刷新系统通知")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard contactStore.beginGroupInviteApprovalProcessing(requestID: approval.requestID) else { return }
        let nextStatus = approve ? "approved" : "rejected"
        let resultText = approve ? "已通过" : "已拒绝"
        Task {
            defer { contactStore.finishGroupInviteApprovalProcessing(requestID: approval.requestID) }
            do {
                let response = try await api.reviewGroupInviteApproval(context: context, endpoint: endpoint)
                guard isCurrentRemoteScope(scope) else { return }
                markGroupInviteApprovalResolved(
                    requestID: approval.requestID,
                    status: response.resolvedStatus(fallback: nextStatus),
                    approverName: response.resolvedApproverName(fallback: currentUser.name),
                    approverAccountID: response.resolvedApproverAccountID(),
                    decidedAt: displayTime(response.resolvedDecidedAt(fallback: "")),
                    resultText: response.resolvedResultText(fallback: resultText)
                )
                let didMarkRead = await markGroupInviteApprovalInboxReadRemotely(requestID: approval.requestID, context: context, scope: scope)
                guard isCurrentRemoteScope(scope) else { return }
                if didMarkRead {
                    markGroupInviteApprovalReadLocally(requestID: approval.requestID)
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(approve ? "已通过入群邀请" : "已拒绝入群邀请")
                } else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(approve ? "已通过入群邀请，但通知已读同步失败" : "已拒绝入群邀请，但通知已读同步失败")
                }
                await refreshInboxSilently()
                guard isCurrentRemoteScope(scope) else { return }
                _ = await refreshRemoteSnapshot(silent: true, force: true)
            } catch IMAPIError.conflict(let code, _) where Self.isGroupInviteAlreadyProcessedCode(code) {
                guard isCurrentRemoteScope(scope) else { return }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该入群邀请已被其他管理员处理")
                markGroupInviteApprovalResolved(requestID: approval.requestID, status: "processed", resultText: "已处理")
                let didMarkRead = await markGroupInviteApprovalInboxReadRemotely(requestID: approval.requestID, context: context, scope: scope)
                guard isCurrentRemoteScope(scope) else { return }
                if didMarkRead {
                    markGroupInviteApprovalReadLocally(requestID: approval.requestID)
                } else {
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("该入群邀请已处理，但通知已读同步失败")
                }
                await refreshInboxSilently()
                guard isCurrentRemoteScope(scope) else { return }
                _ = await refreshRemoteSnapshot(silent: true, force: true)
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                handleRemoteError(error, fallback: approve ? "审批通过失败" : "审批拒绝失败")
                await refreshInboxSilently()
            }
        }
    }

    private static func isGroupInviteAlreadyProcessedCode(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "already_processed" || normalized == "group_invite_already_processed"
    }

    private func markGroupInviteApprovalResolved(requestID: String, status: String, approverName: String = "", approverAccountID: String = "", decidedAt: String = "", resultText: String = "") {
        guard !requestID.isEmpty else { return }
        var didUpdateInbox = false
        for index in inboxItems.indices {
            guard let approval = inboxItems[index].groupInviteApproval,
                  approval.requestID == requestID else { continue }
            inboxItems[index] = inboxItems[index].withGroupInviteApproval(approval.resolved(status: status, approverName: approverName, approverAccountID: approverAccountID, decidedAt: decidedAt, resultText: resultText))
            didUpdateInbox = true
        }
	        if didUpdateInbox {
	            syncSystemConversationFromInbox(inboxItems)
        }
        conversationStore.resolveGroupInviteApprovalMessages(
            requestID: requestID,
            status: status,
            approverName: approverName,
            approverAccountID: approverAccountID,
            decidedAt: decidedAt,
            resultText: resultText
        )
    }

    private func markGroupInviteApprovalReadLocally(requestID: String) {
        guard !requestID.isEmpty else { return }
        var didUpdateInbox = false
        for index in inboxItems.indices {
            guard !inboxItems[index].isAnnouncement,
                  inboxItems[index].groupInviteApproval?.requestID == requestID else { continue }
            contactStore.rememberSystemInboxReadLocally(id: inboxItems[index].id)
            if !inboxItems[index].isRead {
                inboxItems[index].isRead = true
                didUpdateInbox = true
            }
        }
        if didUpdateInbox {
            syncSystemConversationFromInbox(inboxItems)
        }
    }

    private func markGroupInviteApprovalInboxReadRemotely(requestID: String, context: IMAPIContext, scope: String) async -> Bool {
        guard isCurrentRemoteScope(scope) else { return false }
        let ids = inboxItems.compactMap { item -> String? in
            guard !item.isAnnouncement,
                  item.groupInviteApproval?.requestID == requestID else { return nil }
            return item.id
        }
        guard !ids.isEmpty else { return true }
        for id in ids {
            do {
                try await api.markInboxRead(context: context, id: id)
                guard isCurrentRemoteScope(scope) else { return false }
            } catch {
                guard isCurrentRemoteScope(scope) else { return false }
                handleRemoteError(error, fallback: "通知状态同步失败", silent: true)
                return false
            }
        }
        return true
    }

    func markInboxRead(_ itemID: String) {
        guard let index = inboxItems.firstIndex(where: { $0.id == itemID }) else { return }
        let previousItem = inboxItems[index]
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        Task {
            do {
                try await api.markInboxRead(context: context, id: itemID)
                guard isCurrentRemoteScope(scope) else { return }
                if let currentIndex = inboxItems.firstIndex(where: { $0.id == itemID }) {
                    if !inboxItems[currentIndex].isAnnouncement {
                        contactStore.rememberSystemInboxReadLocally(id: inboxItems[currentIndex].id)
                    }
                    inboxItems[currentIndex].isRead = true
                    syncSystemConversationFromInbox(inboxItems)
                }
                await refreshInboxSilently()
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                if let currentIndex = inboxItems.firstIndex(where: { $0.id == itemID }) {
                    inboxItems[currentIndex] = previousItem
                }
                handleRemoteError(error, fallback: "通知状态同步失败")
            }
        }
    }

    func markSystemInboxReadLocally() {
        guard !inboxItems.isEmpty else {
            clearConversationUnreadLocally("system_notification")
            return
        }
        var didChange = false
        for index in inboxItems.indices where !inboxItems[index].isAnnouncement {
            contactStore.rememberSystemInboxReadLocally(id: inboxItems[index].id)
            if !inboxItems[index].isRead {
                inboxItems[index].isRead = true
                didChange = true
            }
        }
        if didChange {
            syncSystemConversationFromInbox(inboxItems)
        } else {
            clearConversationUnreadLocally("system_notification")
        }
    }

    func startInboxRefreshLoop() {
        stopInboxRefreshLoop()
        guard apiContext.hasIMSession else { return }
        let syncEngine = remoteSyncEngine
        guard let taskToken = syncEngine.claimInboxRefreshTask() else { return }
        let task = Task { [weak self, syncEngine, taskToken] in
            defer { syncEngine.finishInboxRefreshTask(taskToken) }
            await self?.refreshInboxAndFriendPresenceSilently()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refreshInboxAndFriendPresenceSilently()
            }
        }
        syncEngine.attachInboxRefreshTask(taskToken, task: task)
    }

    func stopInboxRefreshLoop() {
        remoteSyncEngine.cancelInboxRefreshTask()
        stopRTCCallRefreshLoop()
    }

    func refreshInboxSilently() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else {
            stopInboxRefreshLoop()
            return
        }
        do {
            let inbox = try await api.listInbox(context: context)
            let announcements = (try? await api.listAnnouncementInbox(context: context)) ?? []
            guard isCurrentRemoteScope(scope) else { return }
            applyInbox(Self.mergedInboxEntries(inbox, announcements))
        } catch {
            guard isCurrentRemoteScope(scope) else { return }
            // 收件箱刷新是准实时增强；只有企业访问状态码需要同步入口状态。
            if let securityInfo = securityBlockedInfo(from: error) {
                handleSecurityBlocked(securityInfo)
            } else if let code = workspaceAccessCode(from: error) {
                let affectsCurrent = markWorkspaceAccessBlocked(code)
                if affectsCurrent {
                    disconnectRealtime(shouldReconnect: false)
                    bootstrapPresentationStore.sync.syncFailureMessage = workspaceAccessMessage(for: code) // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                    forceWorkspaceSelectionForCurrentAccessBlock(code)
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(workspaceAccessMessage(for: code))
            }
        }
    }

    private func refreshInboxAndFriendPresenceSilently() async {
        await refreshInboxSilently()
        guard !Task.isCancelled else { return }
        await refreshFriendPresenceSilently()
    }

    private func refreshFriendPresenceSilently() async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let generation = localMessageSessionGeneration
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        profileContactRevisionFence.rebind(scopeHash: scope)
        let readStamp = profileContactRevisionFence.beginRead(scopeHash: scope)
        guard let relations = try? await api.listFriends(context: context) else { return }
        do { try await waitForDirectoryOrConversationScrollToEnd(scope: scope) }
        catch { return }
        guard generation == localMessageSessionGeneration, isCurrentRemoteScope(scope) else { return }
        applyFriendRelations(relations, readStamp: readStamp)
    }

    func waitForDirectoryOrConversationScrollToEnd(scope: String) async throws {
        while isContactDirectoryUserInteracting || isConversationListUserInteracting {
            try Task.checkCancellation()
            guard isCurrentRemoteScope(scope) else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        try Task.checkCancellation()
    }

#if DEBUG
    func refreshFriendPresenceForTesting() async {
        await refreshFriendPresenceSilently()
    }
#endif

    func toggleDeviceBlocked(_ deviceID: String) {
        guard let index = deviceSessions.firstIndex(where: { $0.id == deviceID }) else { return }
        deviceSessions[index].isBlocked.toggle()
        deviceSessions[index].status = deviceSessions[index].isBlocked ? "已封禁" : "可信设备"
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(deviceSessions[index].isBlocked ? "已提交设备封禁" : "已解除设备封禁")
    }

}

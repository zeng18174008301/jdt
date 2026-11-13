// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
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

    /// 返回是否真正发起了旧消息加载请求。节流、窗口不可用、已到最早消息等
    /// 情况下返回 false,调用方据此决定是否关闭各自的重试门。
    @discardableResult
    func loadOlderMessagesIfAvailable(
        _ conversationID: String,
        waitForViewportIdle: @escaping @MainActor () async -> Bool = { true }
    ) -> Bool {
        guard apiContext.hasIMSession else {
            return loadOlderPersistedMessagesIfAvailable(conversationID, waitForViewportIdle: waitForViewportIdle)
        }
        let context = apiContext
        let requestGeneration = localMessageSessionGeneration // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110
        let scope = remoteDataScopeKey(for: context)
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */ else {
            return loadOlderPersistedMessagesIfAvailable(conversationID, waitForViewportIdle: waitForViewportIdle)
        }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        guard !conversationStore.isHistoryLoading(conversationID: conversationID) else { return false }
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        let availabilityPlan = conversationStore.olderHistoryAvailabilityPlan(for: conversation, historyKey: historyKey)
        guard case .available(let availabilityTarget) = availabilityPlan else {
            if case .reachedStart(_, let plannedConversationID) = availabilityPlan {
                conversationStore.setHistoryMessage(
                    conversationID: plannedConversationID,
                    message: historyLimitedReachedStartMessage(for: conversation)
                )
                return false
            }
            guard case .unavailable(_, let plannedConversationID) = availabilityPlan else { return false }
            // 窗口不可用是瞬态(常见于窗口里只有 channelSeq==0 的本地/系统消息),
            // 不再写入 historyReachedStartKeys 形成黏性死锁。若会话明确存在历史
            // (lastMsgSeq > 1),先强制同步一次最新窗口修复本地窗口,再走正常分页。
            if conversation.lastMsgSeq > 1, historyWindowRecoverySyncAttemptedKeys.insert(historyKey).inserted {
                syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: true,
                    trimToLatestWindow: true
                )
                return false
            }
            conversationStore.setHistoryMessage(
                conversationID: plannedConversationID,
                message: historyLimitedReachedStartMessage(for: conversation)
            )
            return false
        }
        let plannedHistoryKey = availabilityTarget.historyKey
        let plannedConversationID = availabilityTarget.conversationID
        let oldestSeq = availabilityTarget.oldestSeq
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let pageLimit = 50
        // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：旧分页去重索引延后到后台任务构建，避免进入历史加载时同步扫消息
        let existingMessagesSnapshot = conversation.messages
        // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
        guard let historyClaim = conversationStore.beginOlderHistoryLoadClaim( // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            historyKey: plannedHistoryKey,
            conversationID: plannedConversationID,
            now: Date(),
            throttleInterval: conversationHistoryLoadThrottleInterval
        ) else {
            return false
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        Task {
            // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：旧分页去重索引后台构建
            async let existingWindowIndex = MessageHistoryPreparationBuilder.olderWindowIndexOffMain(
                messages: existingMessagesSnapshot,
                oldestSeq: oldestSeq
            )
            // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
            defer {
                conversationStore.finishHistorySync(historyClaim) // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            }
            do {
                if let ticket = localMessageTicket,
                   let persisted = try? await messagePersistence.loadOlderMessages(
                       ticket: ticket,
                       channelKey: channelID,
                       beforeSeq: oldestSeq,
                       limit: pageLimit
                   ),
                   isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */ {
                    // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：本地缓存消息恢复放到后台
                    let persistedModels = await MessageHistoryPreparationBuilder.cachedMessageModelsOffMain(persisted)
                    guard await waitForViewportIdle(),
                          isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */ else { return }
                    _ = conversationStore.mergePersistedMessagePage(
                        persistedModels,
                        conversationID: plannedConversationID
                    )
                    // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
                }
                let tracedPage = try await traceMessageHTTPRequest {
                    try await api.syncMessagesBefore(
                        context: context,
                        channelID: channelID,
                        channelType: channelType,
                        beforeSeq: oldestSeq,
                        limit: pageLimit
                    )
                }
                let page = tracedPage.value
                guard await waitForViewportIdle(),
                      isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */,
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                let syncBoundary = historyBoundary(from: page, channelType: channelType)
                if let syncBoundary {
                    applyHistoryVisibilityBoundaryForGroup(
                        channelID: channelID,
                        boundary: syncBoundary
                    )
                }
                // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：使用后台构建的旧分页去重索引
                let windowIndex = await existingWindowIndex
                // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_BEGIN
                guard isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession),
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_END
                let olderMessages = page.items.filter { remote in
                    isRemoteMessageVisibleAfterHistoryBoundary(remote, boundary: syncBoundary)
                        &&
                    isRemoteMessageOlderThanCurrentWindow(
                        remote,
                        oldestSeq: oldestSeq,
                        existingIDs: windowIndex.existingIDs,
                        existingSeqs: windowIndex.existingSeqs
                    )
                }
                // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
                guard !olderMessages.isEmpty else {
                    let reachedHistoryBoundary = syncBoundary?.isRestrictive == true
                        || (page.hasMoreBefore == false && syncBoundary?.limited == true)
                    conversationStore.markOlderHistoryReachedStart(
                        historyKey: plannedHistoryKey,
                        conversationID: plannedConversationID,
                        message: reachedHistoryBoundary ? groupHistoryLimitedMessage : "已同步到最早消息"
                    )
                    await persistConversationSnapshotImmediately(
                        conversationID: plannedConversationID,
                        scope: scope,
                        source: .history
                    )
                    return
                }
                // JHT_MOD_BEGIN CHAT_HISTORY_SYNC_UI_PERF_BEGIN_OLDER_REMOTE_PREPEND_CONTEXT - 修改开始：旧消息远端分页传入 beforeSeq，合并层可走保守增量路径
                guard await applyRemoteMessagesFromAsyncEntry(
                    olderMessages,
                    channelID: channelID,
                    channelType: channelType,
                    historyBoundary: syncBoundary,
                    olderHistoryBeforeSeq: oldestSeq, sourceCorrelations: [tracedPage.sourceCorrelation], onApplied: {
                        self.conversationStore.markOlderHistoryApplied(historyKey: plannedHistoryKey, conversationID: plannedConversationID)
                        self.historyWindowRecoverySyncAttemptedKeys.remove(plannedHistoryKey)
                    }, isCurrent: {
                        self.isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession)
                            && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration)
                    }
                ) else { return }
                // JHT_MOD_END CHAT_HISTORY_SYNC_UI_PERF_END_OLDER_REMOTE_PREPEND_CONTEXT - 修改结束：旧消息远端分页传入 beforeSeq，合并层可走保守增量路径
                await persistConversationSnapshotImmediately(
                    conversationID: plannedConversationID,
                    scope: scope,
                    source: .history
                )
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            } catch {
                guard isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) else { return } // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    conversationStore.setHistoryMessage(conversationID: plannedConversationID, message: "更早聊天记录同步失败，请稍后重试")
                    handleRemoteError(error, fallback: "聊天记录同步失败", silent: true)
                }
            }
        }
        return true
    }

    @discardableResult
    private func loadOlderPersistedMessagesIfAvailable(
        _ conversationID: String,
        waitForViewportIdle: @escaping @MainActor () async -> Bool
    ) -> Bool {
        guard !conversationStore.isHistoryLoading(conversationID: conversationID),
              let ticket = localMessageTicket,
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
        let oldestSeq = conversation.messages
            .map(\.channelSeq)
            .filter { $0 > 0 }
            .min() ?? 0
        guard oldestSeq > 0 else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        guard let historyClaim = conversationStore.beginOlderHistoryLoadClaim( // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            historyKey: historyKey,
            conversationID: conversationID,
            now: Date(),
            throttleInterval: conversationHistoryLoadThrottleInterval
        ) else { return false }
        let channelID = remoteChannelID(for: conversation)
        Task {
            defer {
                conversationStore.finishHistorySync(historyClaim) // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            }
            guard let persisted = try? await messagePersistence.loadOlderMessages(
                ticket: ticket,
                channelKey: channelID,
                beforeSeq: oldestSeq,
                limit: 50
            ),
                  localMessageTicket?.scopeHash == ticket.scopeHash else { return }
            if persisted.isEmpty {
                conversationStore.setHistoryMessage(
                    conversationID: conversationID,
                    message: "本地已无更早记录，联网后继续同步"
                )
                return
            }
            // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：离线本地分页消息恢复放到后台
            let persistedModels = await MessageHistoryPreparationBuilder.cachedMessageModelsOffMain(persisted)
            guard await waitForViewportIdle(), localMessageTicket == ticket else { return }
            _ = conversationStore.mergePersistedMessagePage(
                persistedModels,
                conversationID: conversationID
            )
            // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
        }
        return true
    }

    func loadNewerMessagesIfAvailable(_ conversationID: String) {
        guard apiContext.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let context = apiContext
        let requestGeneration = localMessageSessionGeneration // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110
        let scope = remoteDataScopeKey(for: context)
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */ else { return }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        guard !conversationStore.isHistoryLoading(conversationID: conversationID) else { return }
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        let historyKey = conversationHistoryStateKey(for: conversation)
        guard let target = conversationStore.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: historyKey,
            limit: latestConversationMessageWindowLimit
        ) else {
            return
        }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：新分页去重索引延后到后台任务构建
        let existingMessagesSnapshot = conversation.messages
        // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
        guard let historyClaim = conversationStore.beginMessageSyncClaim( // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            historyKey: target.historyKey,
            conversationID: target.conversationID,
            showLoadingIndicator: false
        ) else {
            return
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        Task {
            // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：新分页去重索引后台构建
            async let existingWindowIndex = MessageHistoryPreparationBuilder.newerWindowIndexOffMain(
                messages: existingMessagesSnapshot
            )
            // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
            defer {
                conversationStore.finishHistorySync(historyClaim) // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            }
            do {
                let tracedPage = try await traceMessageHTTPRequest {
                    try await api.syncMessages(
                        context: context,
                        channelID: channelID,
                        channelType: channelType,
                        afterSeq: target.afterSeq,
                        limit: target.limit
                    )
                }
                let page = tracedPage.value
                guard isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */,
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                let syncBoundary = historyBoundary(from: page, channelType: channelType)
                // JHT_MOD_BEGIN CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改开始：使用后台构建的新分页去重索引
                let windowIndex = await existingWindowIndex
                // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_BEGIN
                guard isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession),
                      isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration) else { return }
                // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_END
                let newerMessages = page.items.filter { remote in
                    isRemoteMessageVisibleAfterHistoryBoundary(remote, boundary: syncBoundary)
                        &&
                    isRemoteMessageNewerThanCurrentWindow(
                        remote,
                        newestSeq: target.afterSeq,
                        existingIDs: windowIndex.existingIDs,
                        existingSeqs: windowIndex.existingSeqs
                    )
                }
                // JHT_MOD_END CHAT_HISTORY_PREP_ASYNC_PERF_20260913 - 修改结束
                guard !newerMessages.isEmpty else {
                    if let syncBoundary {
                        applyHistoryVisibilityBoundaryForGroup(
                            channelID: channelID,
                            boundary: syncBoundary
                        )
                    }
                    return
                }
                guard await applyRemoteMessagesFromAsyncEntry(newerMessages, channelID: channelID, channelType: channelType,
                    historyBoundary: syncBoundary, sourceCorrelations: [tracedPage.sourceCorrelation], isCurrent: {
                        self.isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession)
                            && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID, channelType: channelType, generation: boundaryGeneration)
                    }) else { return }
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            } catch {
                guard isCurrentHistoryPageRequest(context: context, scope: scope, generation: requestGeneration, refreshSession: refreshSession) /* WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110 */ else { return }
                if isNotFriendsError(error) {
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    logSyncEndpointFailure("/api/im/sync", error: error, channelID: channelID, channelType: channelType)
                }
            }
        }
    }

    // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_BEGIN
    private func isCurrentHistoryPageRequest(
        context: IMAPIContext, scope: String, generation: UInt64,
        refreshSession: RemoteSnapshotRefreshSession
    ) -> Bool {
        !Task.isCancelled && generation == localMessageSessionGeneration
            && context.sessionEpoch == apiContext.sessionEpoch
            && isCurrentRemoteRefresh(refreshSession, scope: scope)
    }
    // WDT_IOS1_REFACTOR_MESSAGE_CALLBACK_SCOPE_20261110_END

    func hasOlderMessagesAvailable(_ conversationID: String) -> Bool {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        return conversationStore.olderHistoryAvailabilityTarget(for: conversation, historyKey: historyKey) != nil
    }

    func hasNewerMessagesAvailable(_ conversationID: String) -> Bool {
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return false }
        let historyKey = conversationHistoryStateKey(for: conversation)
        return conversationStore.newerHistoryAvailabilityTarget(
            for: conversation,
            historyKey: historyKey,
            limit: latestConversationMessageWindowLimit
        ) != nil
    }

    func conversationHistoryStateKey(for conversation: ConversationMessageSnapshot) -> String {
        conversationStore.conversationHistoryKeyContext(
            tenantID: apiContext.tenantID,
            imUID: apiContext.imUID,
            conversationID: conversation.id
        ).historyKey
    }

    private func isRemoteMessageOlderThanCurrentWindow(_ remote: RemoteMessage, oldestSeq: Int64, existingIDs: Set<String>, existingSeqs: Set<Int64>) -> Bool {
        conversationStore.isRemoteMessageOlderThanCurrentWindow(
            remote,
            oldestSeq: oldestSeq,
            existingIDs: existingIDs,
            existingSeqs: existingSeqs
        )
    }

    private func isRemoteMessageNewerThanCurrentWindow(_ remote: RemoteMessage, newestSeq: Int64, existingIDs: Set<String>, existingSeqs: Set<Int64>) -> Bool {
        conversationStore.isRemoteMessageNewerThanCurrentWindow(
            remote,
            newestSeq: newestSeq,
            existingIDs: existingIDs,
            existingSeqs: existingSeqs
        )
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END

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
    func clearConversationUnreadLocally(_ conversationID: String) {
        conversationStore.clearUnread(conversationID: conversationID) { channelID in
            conversationKind(from: "", channelID: channelID) == .system
        }
    }

    @discardableResult
    func rememberConversationReadLocally(_ conversation: ConversationMessageSnapshot, through confirmedSeq: Int64? = nil) -> Int64 {
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let readSeq = confirmedSeq ?? latestReadableSequence(in: conversation)
        guard !channelID.isEmpty, readSeq > 0 else { return 0 }
        let key = conversationReadStateKey(channelID: channelID, channelType: channelType)
        if let scope = currentReadWatermarkScope(channelID: channelID, channelType: channelType),
           let watermark = ConversationStore.ReadWatermark(
            eventID: "",
            tenantID: scope.tenantID,
            imUID: scope.imUID,
            appID: scope.appID,
            channelID: scope.channelID,
            channelType: scope.channelType,
            lastReadSeq: readSeq
           ) {
            let effectiveReadSeq = conversationStore.rememberReadWatermark(watermark)
            conversationStore.rememberRead(key: key, readSeq: effectiveReadSeq)
            return max(effectiveReadSeq, conversationStore.locallyReadSeq(forKey: key))
        }
        conversationStore.rememberRead(key: key, readSeq: readSeq)
        return conversationStore.locallyReadSeq(forKey: key)
    }

    func cancelLocalNotificationsForCurrentRead(channelID: String, channelType: String, throughSeq: Int64) {
        guard throughSeq > 0,
              let scope = currentReadWatermarkScope(channelID: channelID, channelType: channelType) else { return }
        cancelLocalNotifications(for: scope, throughSeq: throughSeq)
    }

    func rememberSystemInboxReadAck(_ ack: RemoteIMReadAckTarget?, fallback conversation: ConversationMessageSnapshot) {
        let channelType = ack?.channelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? ack!.channelType
            : apiChannelType(for: conversation.kind)
        let channelID = ack?.channelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? ack!.channelID
            : remoteChannelID(for: conversation)
        let readSeq = max(ack?.lastRead ?? 0, latestReadableSequence(in: conversation))
        guard !channelID.isEmpty, readSeq > 0 else { return }
        let key = conversationReadStateKey(channelID: channelID, channelType: channelType)
        if let scope = currentReadWatermarkScope(channelID: channelID, channelType: channelType),
           let watermark = ConversationStore.ReadWatermark(
            eventID: "",
            tenantID: scope.tenantID,
            imUID: scope.imUID,
            appID: scope.appID,
            channelID: scope.channelID,
            channelType: scope.channelType,
            lastReadSeq: readSeq
           ) {
            let effectiveReadSeq = conversationStore.rememberReadWatermark(watermark)
            conversationStore.rememberRead(key: key, readSeq: effectiveReadSeq)
        } else {
            conversationStore.rememberRead(key: key, readSeq: readSeq)
        }
    }

    func latestReadableSequence(in conversation: ConversationMessageSnapshot) -> Int64 {
        conversationStore.latestReadableSequence(in: conversation)
    }

    func conversationReadStateKey(channelID: String, channelType: String, lookup: ConversationUserLookup? = nil) -> String {
        conversationStore.conversationReadStateKeyContext(
            channelID: channelID,
            channelType: channelType,
            normalizeChannelID: { rawChannelID, rawChannelType in
                normalizedRemoteChannelID(rawChannelID, channelType: rawChannelType, lookup: lookup)
            }
        ).syncKey
    }

    func waitForConversationListInteractionToEnd(
        scope: String,
        pause: @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws {
        while isConversationListUserInteracting {
            try Task.checkCancellation()
            guard isCurrentRemoteScope(scope) else { throw CancellationError() }
            try await pause(16_000_000)
        }
        try Task.checkCancellation()
    }

    func isConversationLocallyReadThrough(_ remote: RemoteConversation) -> Bool {
        guard remote.lastMsgSeq > 0 else { return false }
        let key = conversationReadStateKey(channelID: remote.channelID, channelType: remote.channelType)
        return conversationStore.isLocallyReadThrough(key: key, lastMessageSeq: remote.lastMsgSeq)
    }

    func locallyReadSeq(for remote: RemoteConversation) -> Int64 {
        let key = conversationReadStateKey(channelID: remote.channelID, channelType: remote.channelType)
        return conversationStore.locallyReadSeq(forKey: key)
    }

    func syncConversationMessagesIfNeeded(
        _ conversationID: String,
        force: Bool = false,
        silent: Bool = false,
        showLoadingIndicator: Bool = true,
        trimToLatestWindow: Bool = false,
        authRecoveryAllowed: Bool = true
    ) {
        guard apiContext.hasIMSession else {
            if !silent {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            }
            return
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let selectionToken = conversationSelectionEpochFence.token(
            scope: scope,
            conversationID: conversationID
        )
        guard let refreshSession = remoteSyncEngine.currentRemoteSnapshotRefreshSession(),
              isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        guard let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let latestHistoryWindowLimit = latestConversationMessageWindowLimit
        let windowRetention: ConversationStore.MessageWindowRetention = trimToLatestWindow
            ? .latestTail(limit: latestHistoryWindowLimit)
            : .preserveLoadedHistory
        let historyKey = conversationHistoryStateKey(for: conversation)
        let syncPlan = conversationStore.messageSyncPlan(
            for: conversation,
            historyKey: historyKey,
            force: force,
            latestHistoryWindowLimit: latestHistoryWindowLimit
        )
        if syncPlan == .sidecarsOnly {
            Task {
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            }
            return
        }
        guard case .remoteHistory(let plannedHistoryKey, let syncWindows) = syncPlan else { return }
        guard let historyClaim = conversationStore.beginMessageSyncClaim( // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            historyKey: plannedHistoryKey,
            conversationID: conversationID,
            showLoadingIndicator: showLoadingIndicator
        ) else {
            return
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: channelID, channelType: channelType)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let cachedMessageCount = conversation.messages.count
        Task {
            var diagnostic: SyncFailureDiagnostic.HTTPObservation?
            defer {
                conversationStore.finishHistorySync(historyClaim) // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            }
            // WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_BEGIN
            let isCurrentHistoryResult: @MainActor () -> Bool = {
                self.isCurrentRemoteRefresh(refreshSession, scope: scope)
                    && context.sessionEpoch == self.apiContext.sessionEpoch
                    && (selectionToken.map { self.conversationSelectionEpochFence.accepts($0) } ?? true)
                    && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID,
                        channelType: channelType, generation: boundaryGeneration)
            }
            do {
                var messages: [RemoteMessage] = []
                var sourceCorrelations: [UInt64] = []
                var syncBoundary: ConversationStore.HistoryVisibilityBoundary?
                for window in syncWindows {
                    let requestDiagnostic = SyncFailureDiagnostic.HTTPObservation(.history)
                    diagnostic = requestDiagnostic
                    let traced = try await traceMessageHTTPRequest {
                        try await SyncFailureDiagnostic.$httpObservation.withValue(requestDiagnostic) {
                            defer { requestDiagnostic.finish() }
                            return try await requestDiagnostic.perform {
                                try await api.syncMessages(
                                    context: context, channelID: channelID, channelType: channelType,
                                    afterSeq: window.afterSeq, limit: window.limit
                                )
                            }
                        }
                    }
                    guard isCurrentHistoryResult() else { return }
                    let page = traced.value
                    syncBoundary = historyBoundary(from: page, channelType: channelType) ?? syncBoundary
                    messages.append(contentsOf: page.items)
                    sourceCorrelations.append(traced.sourceCorrelation)
                }
                guard isCurrentHistoryResult() else { return }
                if messages.isEmpty {
                    clearSyncFailureDiagnostics(for: .history)
                    if let syncBoundary {
                        applyHistoryVisibilityBoundaryForGroup(
                            channelID: channelID,
                            boundary: syncBoundary
                        )
                    }
                    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                    DebugConsoleDiagnostics.trace("[JHT Perf] chat_history_ready_ms=\(elapsedMs) remote_messages=0 cached_messages=\(cachedMessageCount) forced=\(force) loading=\(showLoadingIndicator)")
                    if showLoadingIndicator || conversation.messages.isEmpty {
                        conversationStore.setHistoryMessage(
                            conversationID: conversationID,
                            message: syncBoundary?.isRestrictive == true ? groupHistoryLimitedMessage : (conversation.messages.isEmpty ? "暂无历史消息" : nil)
                        )
                    }
                    // Reading history does not establish a friendship or grant sending rights.
                    await syncReadReceiptsForConversation(channelID: channelID, channelType: channelType, session: sidecarSession)
                    return
                }
                guard await applyRemoteMessagesFromAsyncEntry(
                    messages, channelID: channelID, channelType: channelType,
                    windowRetention: windowRetention, historyBoundary: syncBoundary,
                    sequenceCoverageAfterSeq: syncWindows.map(\.afterSeq).min(),
                    sourceCorrelations: sourceCorrelations, onApplied: {
                        self.clearSyncFailureDiagnostics(for: .history)
                        self.conversationStore.setHistoryMessage(conversationID: conversationID, message: nil)
                    }, isCurrent: isCurrentHistoryResult
                ), isCurrentHistoryResult() else { return }
                // WDT_IOS1_PHASE6_PRODUCTION_CHAIN_20261111_END
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                DebugConsoleDiagnostics.trace("[JHT Perf] chat_history_ready_ms=\(elapsedMs) remote_messages=\(messages.count) cached_messages=\(cachedMessageCount) forced=\(force) loading=\(showLoadingIndicator)")
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: sidecarSession)
            } catch {
                guard isCurrentHistoryResult() else { return }
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                DebugConsoleDiagnostics.trace("[JHT Perf] chat_history_failed_ms=\(elapsedMs) cached_messages=\(cachedMessageCount) forced=\(force) loading=\(showLoadingIndicator)")
                if isNotFriendsError(error) {
                    recordSyncFailureDiagnostic(error, endpoint: .history, httpFailure: diagnostic?.failure)
                    handleNotFriends(for: conversation, showToast: false)
                } else {
                    if showLoadingIndicator {
                        conversationStore.setHistoryMessage(conversationID: conversationID, message: "聊天记录同步失败，请稍后重试")
                    }
                    handleConversationHistorySyncError(
                        error,
                        conversationID: conversationID,
                        silent: silent,
                        authRecoveryAllowed: authRecoveryAllowed,
                        httpFailure: diagnostic?.failure
                    )
                }
            }
        }
    }

    func prepareConversationTailWindowForEntry(_ conversationID: String) {
        conversationStore.trimConversationToLatestWindow(
            conversationID: conversationID,
            limit: latestConversationMessageWindowLimit
        )
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        guard apiContext.hasIMSession, let client = api as? IMAPIClient,
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID),
              !isSystemReadOnlyConversation(conversation) else { return }
        client.scheduleOpeningConversationRouteRead(context: apiContext, channelID: remoteChannelID(for: conversation),
            channelType: apiChannelType(for: conversation.kind), afterSeq: latestReadableSequence(in: conversation))
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
    }

    private func handleConversationHistorySyncError(
        _ error: Error,
        conversationID: String,
        silent: Bool,
        authRecoveryAllowed: Bool,
        httpFailure: SyncFailureDiagnostic.Failure? = nil
    ) {
        let unauthorized = isUnauthorizedError(error)
        let deviceRevoked = unauthorized && DeviceRevocationDetector.matches(error: error)
        let recovery: SyncFailureDiagnostic.Recovery = !unauthorized ? .notApplicable
            : deviceRevoked ? .deviceRevoked
            : !authRecoveryAllowed ? .notAllowed
            : !apiContext.hasRefreshSession ? .noRefreshAuthority : .attempted
        recordSyncFailureDiagnostic(error, endpoint: .history, recovery: recovery, httpFailure: httpFailure)
        if unauthorized, !deviceRevoked {
            let context = apiContext
            let scope = remoteDataScopeKey(for: context)
            applySyncFailure(error, silent: silent)
            if !silent {
                showRemoteErrorToast("聊天记录同步失败：登录状态暂时无法验证，请稍后重试")
            }
            guard authRecoveryAllowed, context.hasRefreshSession else {
                logSyncEndpointFailure("/api/im/sync", error: error)
                return
            }
            Task { [weak self, context, scope] in
                guard let self else { return }
                let refreshed = await self.refreshStoredAuthSessionIfNeeded(
                    reason: "conversation_history",
                    silent: true,
                    context: context,
                    scope: scope
                )
                guard refreshed,
                      self.isAuthenticated,
                      self.isCurrentRemoteScope(scope) else { return }
                await Task.yield()
                self.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: false,
                    trimToLatestWindow: false,
                    authRecoveryAllowed: false
                )
            }
            return
        }
        if silent {
            logSyncEndpointFailure("/api/im/sync", error: error)
            if workspaceAccessCode(from: error) != nil || isUnauthorizedError(error) {
                handleRemoteError(error, fallback: "聊天记录同步失败", silent: false)
            }
            return
        }
        guard conversationStore.shouldShowHistorySyncErrorToast(conversationID: conversationID) else {
            logSyncEndpointFailure("/api/im/sync", error: error)
            return
        }
        handleRemoteError(error, fallback: "聊天记录同步失败")
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

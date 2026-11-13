// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_BEGIN
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_BEGIN
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
    func startConversationHistoryPrefetch(_ remoteConversations: [RemoteConversation], context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession, performanceStart: CFAbsoluteTime) {
        let generation = refreshSession.generation
        guard !remoteConversations.isEmpty else {
            print("[JHT Perf] history_prefetch_complete_ms=\(Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)) success=0 failed=0 skipped=empty generation=\(generation)")
            return
        }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.mainShellHistoryPrefetchDelayNs)
            } catch {
                return
            }
            guard self.isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            print("[JHT Perf] history_prefetch_start_delay_ms=\(Int(Double(self.mainShellHistoryPrefetchDelayNs) / 1_000_000)) generation=\(generation)")
            await self.refreshConversationHistories(
                remoteConversations,
                context: context,
                scope: scope,
                refreshSession: refreshSession,
                performanceStart: performanceStart
            )
        }
    }

    private struct HistoryPrefetchResult: @unchecked Sendable {
        let remote: RemoteConversation
        let messages: [RemoteMessage]
        let historyBoundary: ConversationStore.HistoryVisibilityBoundary?
        let boundaryGeneration: Int?
        let readReceiptTarget: ConversationStore.HistoryPrefetchReadReceiptBackfillTarget?
        let error: Error?
    }

    private func historyPrefetchLogID(channelID: String, channelType: String) -> String {
        if conversationKind(from: channelType, channelID: channelID) != .direct {
            return channelID
        }
        let sum = channelID.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return "direct#\(abs(sum % 100_000))"
    }

    private func refreshConversationHistories(_ remoteConversations: [RemoteConversation], context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession, performanceStart: CFAbsoluteTime) async {
        let generation = refreshSession.generation
        guard isCurrentRemoteRefresh(refreshSession, scope: scope),
              context.hasIMSession else { return }
        let lookup = makeConversationUserLookup()
        let canonicalRemotes = canonicalRemoteConversations(remoteConversations, lookup: lookup)
        let localByChannelID = conversationStore.conversationsByChannelID(
            channelIDForConversation: { remoteChannelID(for: $0, lookup: lookup) }
        )
        let activeID = activeRealtimeConversationID ?? ""
        let candidates = canonicalRemotes.map { remote -> ConversationStore.HistoryPrefetchCandidate in
            let channelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType, lookup: lookup)
            let local = localByChannelID[channelID]
            let isActive = !activeID.isEmpty && (activeID == channelID || activeID == local?.id)
            return ConversationStore.HistoryPrefetchCandidate(
                remote: remote,
                channelID: channelID,
                local: local,
                isActive: isActive,
                latestSeq: remoteConversationLatestSeq(remote),
                sortTimestamp: remoteConversationSortTimestamp(remote, previous: local),
                logID: historyPrefetchLogID(channelID: channelID, channelType: remote.channelType)
            )
        }
        let targets = conversationStore.historyPrefetchTargets(candidates: candidates, limit: 6)
        guard !targets.isEmpty else {
            print("[JHT Perf] history_prefetch_complete_ms=\(Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)) success=0 failed=0 skipped=no_candidates generation=\(generation)")
            return
        }
        let prefetchPlan = conversationStore.historyPrefetchExecutionPlan(
            targets: targets,
            messageLimit: latestConversationMessageWindowLimit,
            maxConcurrent: 2
        )
        print("[JHT Perf] history_prefetch_targets generation=\(generation) targets=\(prefetchPlan.targetSummary)")
        var successCount = 0
        var failureCount = 0
        var readReceiptTargets: [(channelID: String, channelType: String)] = []

        for batch in prefetchPlan.batches {
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
            let tasks = batch.map { command in
                let boundaryGeneration = beginGroupHistoryBoundaryRequest(context: context, channelID: command.apiChannelID, channelType: command.channelType)
                return Task(priority: .utility) { [weak self] () -> (HistoryPrefetchResult, UInt64?) in
                    guard let self else {
                        return (HistoryPrefetchResult(remote: command.remote, messages: [], historyBoundary: nil, boundaryGeneration: boundaryGeneration, readReceiptTarget: nil, error: nil), nil)
                    }
                    do {
                        let tracedPage = try await self.traceMessageHTTPRequest {
                            try await self.api.syncMessages(
                                context: context,
                                channelID: command.apiChannelID,
                                channelType: command.channelType,
                                afterSeq: command.afterSeq,
                                limit: command.limit
                            )
                        }
                        let page = tracedPage.value
                        let normalizedChannelType = command.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let historyBoundary = normalizedChannelType == "group"
                            ? ConversationStore.HistoryVisibilityBoundary(
                                fromSeq: page.historyVisibleFromSeq,
                                limited: page.historyLimited,
                                confirmed: true
                            )
                            : nil
                        let readReceiptTarget: ConversationStore.HistoryPrefetchReadReceiptBackfillTarget? = await MainActor.run {
                            guard self.isCurrentRemoteRefresh(refreshSession, scope: scope) else { return nil }
                            return self.conversationStore.historyPrefetchReadReceiptBackfillTarget(
                                for: command,
                                readReceiptsEnabled: self.fileUploadConfig.readReceiptsEnabled,
                                channelIDForConversation: { self.remoteChannelID(for: $0) }
                            )
                        }
                        return (HistoryPrefetchResult(remote: command.remote, messages: page.items, historyBoundary: historyBoundary, boundaryGeneration: boundaryGeneration, readReceiptTarget: readReceiptTarget, error: nil), tracedPage.sourceCorrelation)
                    } catch {
                        return (HistoryPrefetchResult(remote: command.remote, messages: [], historyBoundary: nil, boundaryGeneration: boundaryGeneration, readReceiptTarget: nil, error: error), nil)
                    }
                }
            }

            for task in tasks {
                let (result, sourceCorrelation) = await task.value
                do { try await waitForConversationListInteractionToEnd(scope: scope) }
                catch { return }
                guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return }
                guard isCurrentGroupHistoryBoundaryResponse(context: context, channelID: result.remote.channelID, channelType: result.remote.channelType, generation: result.boundaryGeneration) else { continue }
                if let error = result.error {
                    failureCount += 1
                    logSyncEndpointFailure("/api/im/sync", error: error, channelID: result.remote.channelID, channelType: result.remote.channelType)
                    if isUnauthorizedError(error) {
                        handleRemoteError(error, fallback: "聊天记录同步失败", silent: true)
                        return
                    }
                    continue
                }
                guard await applyRemoteMessagesFromAsyncEntry(
                    result.messages.filter { isRemoteMessageVisibleAfterHistoryBoundary($0, boundary: result.historyBoundary) },
                    channelID: result.remote.channelID,
                    channelType: result.remote.channelType,
                    windowRetention: .latestTail(limit: latestConversationMessageWindowLimit),
                    historyBoundary: result.historyBoundary, sourceCorrelations: sourceCorrelation.map { [$0] } ?? [], isCurrent: {
                        self.isCurrentRemoteRefresh(refreshSession, scope: scope)
                            && context.sessionEpoch == self.apiContext.sessionEpoch
                            && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: result.remote.channelID, channelType: result.remote.channelType, generation: result.boundaryGeneration)
                    }
                ) else { continue }
                successCount += 1
                if let readReceiptTarget = result.readReceiptTarget {
                    readReceiptTargets.append((readReceiptTarget.channelID, readReceiptTarget.channelType))
                }
            }
        }

        if failureCount > 0 {
            print("[JHT Sync] history_partial_failed success=\(successCount) failed=\(failureCount)")
        }
        let finishedMs = Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)
        print("[JHT Perf] history_prefetch_complete_ms=\(finishedMs) success=\(successCount) failed=\(failureCount) targets=\(prefetchPlan.commands.count) generation=\(generation)")
        scheduleRemoteSnapshotCacheWrite(scope: scope, source: .history)

        guard !readReceiptTargets.isEmpty else { return }
        let sidecarSession = MessageSidecarSyncSession(context: context, scope: scope, refreshSession: refreshSession)
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            for target in readReceiptTargets {
                guard await MainActor.run(body: {
                    self.isCurrentRemoteRefresh(refreshSession, scope: scope)
                }) else { return }
                await self.syncReadReceiptsForConversation(
                    channelID: target.channelID,
                    channelType: target.channelType,
                    session: sidecarSession
                )
            }
        }
    }

}
// WDT_IOS1_PHASE6_BACKGROUND_DERIVATION_20261111_END
// WDT_IOS1_PHASE6_HTTP_DIAGNOSTIC_SCOPE_20261111_END

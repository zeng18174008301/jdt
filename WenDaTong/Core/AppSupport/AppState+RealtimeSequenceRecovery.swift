import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
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
    func scheduleMessageSequenceRecovery(
        conversationID: String,
        target: ConversationStore.MessageSequenceRecoveryTarget,
        reason: String
    ) {
        let normalizedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, target.throughSeq > target.afterSeq else { return }
        if let existing = messageSequenceRecoveryTargets[normalizedID] {
            let coalesced = ConversationStore.MessageSequenceRecoveryTarget(
                afterSeq: min(existing.afterSeq, target.afterSeq),
                throughSeq: max(existing.throughSeq, target.throughSeq)
            )
            if coalesced != existing {
                messageSequenceRecoveryAttempts[normalizedID] = 0
            }
            messageSequenceRecoveryTargets[normalizedID] = coalesced
        } else {
            messageSequenceRecoveryTargets[normalizedID] = target
            messageSequenceRecoveryAttempts[normalizedID] = 0
        }
        scheduleRealtimeRecoveryConversationSync(normalizedID, reason: reason)
    }

    func schedulePersistedMessageSequenceRecoveries(reason: String) {
        for conversation in conversationStore.conversationMessageSnapshots()
            where conversation.kind != .system {
            // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
            guard let target = conversationStore.messageSequenceRecoveryTarget(for: conversation)
                ?? messageSequenceRecoveryTargets[conversation.id] else { continue }
            // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END
            messageSequenceRecoveryAttempts[conversation.id] = 0
            scheduleMessageSequenceRecovery(
                conversationID: conversation.id,
                target: target,
                reason: reason
            )
        }
    }

    private func clearCompletedMessageSequenceRecovery( // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111
        conversationID: String,
        coveredThroughSeq: Int64
    ) {
        guard let target = messageSequenceRecoveryTargets[conversationID],
              coveredThroughSeq >= target.throughSeq else { return }
        messageSequenceRecoveryTargets.removeValue(forKey: conversationID)
        messageSequenceRecoveryAttempts.removeValue(forKey: conversationID)
        messageSequenceRecoveryRetryTasks.removeValue(forKey: conversationID)?.cancel()
    }

    private func scheduleMessageSequenceRecoveryRetry(
        conversationID: String,
        reason: String,
        madeProgress: Bool
    ) {
        guard messageSequenceRecoveryTargets[conversationID] != nil,
              messageSequenceRecoveryRetryTasks[conversationID] == nil else { return }
        let previousAttempt = madeProgress ? 0 : (messageSequenceRecoveryAttempts[conversationID] ?? 0)
        let nextAttempt = previousAttempt + 1
        messageSequenceRecoveryAttempts[conversationID] = nextAttempt
        let delays: [UInt64] = [350_000_000, 1_000_000_000, 3_000_000_000]
        guard nextAttempt <= delays.count else { return }
        // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
        let scope = remoteDataScopeKey(for: apiContext)
        let epoch = apiContext.sessionEpoch
        messageSequenceRecoveryRetryTasks[conversationID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delays[nextAttempt - 1])
            guard !Task.isCancelled, let self else { return }
            self.messageSequenceRecoveryRetryTasks[conversationID] = nil
            guard self.isAuthenticated,
                  self.isCurrentRemoteScope(scope),
                  self.apiContext.sessionEpoch == epoch,
                  self.messageSequenceRecoveryTargets[conversationID] != nil else { return }
            // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
            self.scheduleRealtimeRecoveryConversationSync(
                conversationID,
                reason: "sequence_retry_\(reason)"
            )
        }
    }

    func syncMessageSequenceRecovery(
        conversationID: String,
        target: ConversationStore.MessageSequenceRecoveryTarget,
        reason: String
    ) {
        guard apiContext.hasIMSession,
              let conversation = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let historyKey = conversationHistoryStateKey(for: conversation)
        guard let historyClaim = conversationStore.beginMessageSyncClaim( // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            historyKey: historyKey,
            conversationID: conversationID,
            showLoadingIndicator: false
        ) else {
            scheduleMessageSequenceRecoveryRetry(
                conversationID: conversationID,
                reason: "inflight_\(reason)",
                madeProgress: false
            )
            return
        }
        let boundaryGeneration = beginGroupHistoryBoundaryRequest(
            context: context,
            channelID: channelID,
            channelType: channelType
        )
        // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
        let isCurrentRecovery: @MainActor () -> Bool = {
            !Task.isCancelled
                && self.isCurrentRemoteScope(scope)
                && self.apiContext.sessionEpoch == context.sessionEpoch
                && self.conversationStore.isCurrentHistorySyncClaim(historyClaim)
                && self.isCurrentGroupHistoryBoundaryResponse(context: context, channelID: channelID,
                    channelType: channelType, generation: boundaryGeneration)
        }
        // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
        let task = Task { // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112
            defer {
                conversationStore.finishHistorySync(historyClaim) // WDT_IOS1_REFACTOR_HISTORY_SYNC_OWNERSHIP_20261110
            }
            var cursor = target.afterSeq
            // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
            var confirmedCoverage = target.afterSeq
            @MainActor func persistPage() async throws -> Int64 {
                do {
                    return try await commitConversationSnapshot(conversationID: conversationID,
                        scope: scope, source: .history, retryProjectionContention: true, isCurrent: isCurrentRecovery)
                } catch {
                    if isCurrentRecovery() {
                        let failure = error as NSError
                        DebugConsoleDiagnostics.trace("[JHT Sync] sequence_projection_unconfirmed domain=\(failure.domain) code=\(failure.code)")
                    }
                    throw error
                }
            }
            do {
                guard isCurrentRecovery(),
                      let current = conversationStore.conversationMessageSnapshot(id: conversationID) else { return }
                // A prior page, or another normal consumer, may already have filled
                // the in-memory gap. Save it before asking the SDK for more pages.
                if conversationStore.messageSequenceCoveredThrough(in: current) > confirmedCoverage {
                    confirmedCoverage = try await persistPage()
                    guard isCurrentRecovery() else { return }
                    cursor = max(cursor, confirmedCoverage)
                }
                // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END
                for _ in 0..<5 where cursor < target.throughSeq {
                    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
                    guard isCurrentRecovery() else { return }
                    let traced = try await traceMessageHTTPRequest {
                        do { // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
                            return try await api.syncMessages(context: context, channelID: channelID,
                                channelType: channelType, afterSeq: cursor, limit: 100)
                        } catch {
                            if isCurrentRecovery() { logSyncEndpointFailure("/api/im/sync", error: error) }
                            throw error
                        } // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END
                    }
                    guard isCurrentRecovery() else { return }
                    let page = traced.value
                    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
                    let syncBoundary = historyBoundary(from: page, channelType: channelType)
                    if page.items.isEmpty {
                        if let syncBoundary {
                            applyHistoryVisibilityBoundaryForGroup(
                                channelID: channelID,
                                boundary: syncBoundary
                            )
                        }
                        break
                    }
                    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_BEGIN
                    guard await applyRemoteMessagesFromAsyncEntry(page.items, channelID: channelID,
                        channelType: channelType, historyBoundary: syncBoundary,
                        sequenceCoverageAfterSeq: cursor, scheduleSequenceRecovery: false,
                        sourceCorrelations: [traced.sourceCorrelation], isCurrent: isCurrentRecovery),
                        isCurrentRecovery() else { return }
                    confirmedCoverage = try await persistPage() // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111
                    guard isCurrentRecovery() else { return }
                    // WDT_IOS1_SEQUENCE_RECOVERY_WORKER_20261111_END
                    // JHT_MOD_BEGIN APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改开始：实时分页游标避免生成序号临时数组
                    let pageMaxSeq = ConversationSequenceInspector.maximumChannelSeq(in: page.items) ?? cursor
                    // JHT_MOD_END APPSTATE_CHANNEL_SEQ_SCAN_PERF_20260913 - 修改结束
                    let nextCursor = max(page.nextAfterSeq ?? pageMaxSeq, pageMaxSeq)
                    guard nextCursor > cursor else { break }
                    cursor = nextCursor
                    if page.hasMoreAfter != true, page.hasMore != true {
                        break
                    }
                }
            // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_BEGIN
            } catch {
                // The failing fetch or projection recorded its own diagnostic.
                // Keep only confirmed progress for the retry below.
            }
            guard isCurrentRecovery() else { return }
            clearCompletedMessageSequenceRecovery(conversationID: conversationID, coveredThroughSeq: confirmedCoverage)
            if let pending = messageSequenceRecoveryTargets[conversationID] {
                messageSequenceRecoveryTargets[conversationID] = ConversationStore.MessageSequenceRecoveryTarget(
                    afterSeq: max(pending.afterSeq, confirmedCoverage), throughSeq: pending.throughSeq)
                scheduleMessageSequenceRecoveryRetry(conversationID: conversationID, reason: reason,
                    madeProgress: confirmedCoverage > target.afterSeq)
            }
            // WDT_IOS1_SEQUENCE_RECOVERY_DURABILITY_20261111_END
        }
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_BEGIN
#if DEBUG
        realtimeComputeRuntime.onSequenceRecoveryTask?(historyClaim, task)
#else
        _ = task
#endif
        // WDT_IOS1_SEQUENCE_RECOVERY_FIXTURE_DRAIN_20261112_END
    }

    func sendRealtimeSubscribe(for conversation: ConversationMessageSnapshot, lookup: ConversationUserLookup? = nil) {
        guard isRealtimeConnected else { return }
        let channelID = remoteChannelID(for: conversation, lookup: lookup)
        let channelType = apiChannelType(for: conversation.kind)
        realtimeClient.subscribe(
            channelID: channelID,
            channelType: channelType,
            tenantID: apiContext.tenantID ?? "",
            imUID: apiContext.imUID ?? "",
            deviceID: apiContext.deviceID,
            priority: conversation.id == activeRealtimeConversationID
        )
    }

    func resubscribeRealtimeChannels() {
        realtimeResubscriptionTask?.cancel()
        realtimeResubscriptionTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.resubscribeRealtimeChannelsCooperatively()
        }
    }

    func resubscribeRealtimeChannelsCooperatively(
        pause: @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async {
        guard !Task.isCancelled, isRealtimeConnected else { return }
        let scope = remoteDataScopeKey(for: apiContext)
        let generation = localMessageSessionGeneration
        let lookup = makeConversationUserLookup()
        let activeID = activeRealtimeConversationID
        if let activeID, let active = conversationStore.conversationMessageSnapshot(id: activeID) {
            sendRealtimeSubscribe(for: active, lookup: lookup)
        }
        for (index, conversation) in conversationStore.conversationMessageSnapshots().enumerated() {
            if index % 16 == 0 {
                guard !Task.isCancelled, isRealtimeConnected,
                      generation == localMessageSessionGeneration, isCurrentRemoteScope(scope) else { return }
            }
            if conversation.id != activeID {
                sendRealtimeSubscribe(for: conversation, lookup: lookup)
            }
            // Return to the actual run loop between batches so reconnect cannot monopolize touch handling.
            if index % 16 == 15 { try? await pause(1_000_000) }
        }
    }

    // WDT_IOS1_REFACTOR_REALTIME_INGEST_BINDING_20261110_BEGIN
    private func realtimeIngestBindingKey(scope: String) -> String {
        // Reauthentication retains local history, but retires the old remote session.
        // A credential-only refresh keeps both values and may finish its queued merge.
        "\(scope)|\(localMessageSessionGeneration)|\(apiContext.sessionEpoch)"
    }

    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
    func captureRealtimeIngestAdmission() -> RealtimeClient.IncomingAdmission {
        let scope = remoteDataScopeKey(for: apiContext)
        let binding = realtimeIngestBindingKey(scope: scope)
        return { [weak self] in
            guard let self else { return .appScopeRejected }
            guard self.isAuthenticated, self.apiContext.hasIMSession else { return .appAuthRejected }
            guard self.isCurrentRemoteScope(scope),
                  self.realtimeIngestBindingKey(scope: scope) == binding else { return .appScopeRejected }
            return nil
        }
    }
    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END

    func enqueueRealtimeMessage(_ remote: RemoteMessage, usesWorker: Bool = false, signpost: RealtimeMessageFlowSignpost? = nil) -> RealtimeConnectionDiagnostic.Handling {
        guard isAuthenticated, apiContext.hasIMSession else { signpost?.finish(.admissionRejected); return .appAuthRejected }
        let scope = remoteDataScopeKey(for: apiContext)
        guard isCurrentRemoteScope(scope) else { signpost?.finish(.admissionRejected); return .appScopeRejected }
        signpost?.accept(messageID: remote.messageID)
        realtimeIngestBuffer.append(remote, scopeKey: realtimeIngestBindingKey(scope: scope), signpost: signpost)
        if usesWorker { realtimeComputeRuntime.backgroundRequested = true } // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        if realtimeIngestBuffer.count >= realtimeIngestFlushLimit && !usesWorker {
            flushPendingRealtimeMessages(reason: "limit")
        } else {
            scheduleRealtimeIngestFlushIfNeeded()
        }
        return .messageQueued
    }

    private func scheduleRealtimeIngestFlushIfNeeded() {
        guard realtimeIngestFlushTask == nil else { return }
        if realtimeComputeRuntime.backgroundRequested { startRealtimeComputeFlush(afterDelay: true); return }
        realtimeIngestFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: realtimeIngestFlushDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.realtimeIngestFlushTask = nil
            if self.realtimeComputeRuntime.backgroundRequested { self.startRealtimeComputeFlush(afterDelay: false) }
            else { self.flushPendingRealtimeMessages(reason: "timer") }
        }
    }

    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
    func enqueueRealtimeAcknowledgement(_ remote: RemoteMessage, diagnostic: RealtimeEnvelopeDiagnosticObservation?, signpost: RealtimeMessageFlowSignpost? = nil) {
        let scope = remoteDataScopeKey(for: apiContext)
        guard isAuthenticated, apiContext.hasIMSession, isCurrentRemoteScope(scope) else { signpost?.finish(.admissionRejected); return }
        realtimeIngestBuffer.append(remote, scopeKey: realtimeIngestBindingKey(scope: scope),
            acknowledgement: true, diagnostic: diagnostic, signpost: signpost)
        realtimeComputeRuntime.backgroundRequested = true
    }
    private func startRealtimeComputeFlush(afterDelay: Bool) {
        let owner = UUID(); realtimeComputeRuntime.owner = owner
        realtimeIngestFlushTask = Task { @MainActor [weak self] in
            if afterDelay { try? await Task.sleep(nanoseconds: realtimeIngestFlushDelayNanoseconds) }
            guard let self, !Task.isCancelled, self.realtimeComputeRuntime.owner == owner else { return }
            self.isFlushingRealtimeIngest = true
            defer {
                if self.realtimeComputeRuntime.owner == owner {
                    self.isFlushingRealtimeIngest = false; self.realtimeIngestFlushTask = nil
                    self.realtimeComputeRuntime.owner = nil
                    if self.realtimeIngestBuffer.isEmpty { self.realtimeComputeRuntime.backgroundRequested = false }
                    else { self.scheduleRealtimeIngestFlushIfNeeded() }
                }
            }
            let admission = self.captureRealtimeIngestAdmission()
            guard admission() == nil else {
                self.realtimeIngestBuffer.signposts().forEach { $0.finish(.bindingRetired) }
                self.realtimeIngestBuffer.clear(); return
            }
            let scope = self.remoteDataScopeKey(for: self.apiContext)
            self.realtimeIngestBuffer.signposts(excluding: self.realtimeIngestBindingKey(scope: scope)).forEach { $0.finish(.bindingRetired) }
            let works = self.realtimeIngestBuffer.drainWork(currentScopeKey: self.realtimeIngestBindingKey(scope: scope))
            defer { works.flatMap(\.groups).flatMap(\.signposts).forEach { $0.finish(.bindingRetired) } }
            for work in works {
                guard admission() == nil else { return }
                await self.computeAndApplyRealtimeWork(work, admission: admission,
                    isOnlyWork: works.count == 1) // WDT_IOS1_SINGLE_REALTIME_COMMIT_20261112
            }
        }
    }
    func flushPendingRealtimeMessagesSerial() async {
        while !realtimeIngestBuffer.isEmpty || isFlushingRealtimeIngest {
            if !isFlushingRealtimeIngest {
                realtimeIngestFlushTask?.cancel(); realtimeIngestFlushTask = nil
                startRealtimeComputeFlush(afterDelay: false)
            }
            if let task = realtimeIngestFlushTask { await task.value }
        }
    }
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

    func flushPendingRealtimeMessagesIfNeeded(reason: String) {
        guard !realtimeIngestBuffer.isEmpty else { return }
        flushPendingRealtimeMessages(reason: reason)
    }

    private func flushPendingRealtimeMessages(reason: String) {
        guard !isFlushingRealtimeIngest else { return }
        guard isAuthenticated, apiContext.hasIMSession else {
            clearPendingRealtimeMessages(reason: "\(reason)_unauthenticated")
            return
        }
        let scope = remoteDataScopeKey(for: apiContext)
        guard isCurrentRemoteScope(scope) else {
            clearPendingRealtimeMessages(reason: "\(reason)_scope_invalid")
            return
        }
        realtimeIngestFlushTask?.cancel()
        realtimeIngestFlushTask = nil
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
        if realtimeComputeRuntime.backgroundRequested {
            realtimeComputeRuntime.owner = nil
            realtimeIngestBuffer.signposts(excluding: realtimeIngestBindingKey(scope: scope)).forEach { $0.finish(.bindingRetired) }
            let works = realtimeIngestBuffer.drainWork(currentScopeKey: realtimeIngestBindingKey(scope: scope))
            isFlushingRealtimeIngest = true
            defer { isFlushingRealtimeIngest = false; realtimeComputeRuntime.backgroundRequested = false }
            for work in works {
                let apply = {
                    self.conversationStore.performRealtimeAtomicCommand {
                        for group in work.groups {
                            self.applyRemoteMessages(group.messages, channelID: group.channelID, channelType: group.channelType, fromRealtime: true, realtimeSignposts: group.signposts)
                        }
                    }
                }
                if work.acknowledgement { (realtimeClient as? RealtimeClient)?.withEnvelopeDiagnostic(work.diagnostic, apply) }
                else { apply() }
            }
            return
        }
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
        realtimeIngestBuffer.signposts(excluding: realtimeIngestBindingKey(scope: scope)).forEach { $0.finish(.bindingRetired) }
        let groups = realtimeIngestBuffer.drainGrouped(currentScopeKey: realtimeIngestBindingKey(scope: scope))
        guard !groups.isEmpty else { return }
        isFlushingRealtimeIngest = true
        defer { isFlushingRealtimeIngest = false }
        for group in groups {
            applyRemoteMessages(
                group.messages,
                channelID: group.channelID,
                channelType: group.channelType,
                fromRealtime: true, realtimeSignposts: group.signposts
            )
        }
    }
    // WDT_IOS1_REFACTOR_REALTIME_INGEST_BINDING_20261110_END

    func clearPendingRealtimeMessages(reason _: String) {
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
        if realtimeComputeRuntime.backgroundRequested {
            let scope = remoteDataScopeKey(for: apiContext)
            if isAuthenticated, apiContext.hasIMSession, isCurrentRemoteScope(scope) {
                realtimeIngestBuffer.signpostsNotPreservedByClear(currentScopeKey: realtimeIngestBindingKey(scope: scope)).forEach { $0.finish(.bufferCancelled) }
                realtimeIngestBuffer.clearMessagesPreservingAcceptedAcknowledgements(currentScopeKey: realtimeIngestBindingKey(scope: scope))
            } else {
                realtimeIngestBuffer.signposts().forEach { $0.finish(.bufferCancelled) }
                realtimeIngestBuffer.clear()
            }
            if isFlushingRealtimeIngest { return } // An already-admitted active batch completes under its original session lease.
            realtimeComputeRuntime.owner = nil
            realtimeIngestFlushTask?.cancel(); realtimeIngestFlushTask = nil
            if !realtimeIngestBuffer.isEmpty { startRealtimeComputeFlush(afterDelay: false) }
            else { realtimeComputeRuntime.backgroundRequested = false }
            return
        }
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
        realtimeIngestFlushTask?.cancel()
        realtimeIngestFlushTask = nil
        realtimeIngestBuffer.signposts().forEach { $0.finish(.bufferCancelled) }
        realtimeIngestBuffer.clear()
    }

    #if DEBUG
    func pendingRealtimeMessageCountForTesting() -> Int {
        realtimeIngestBuffer.count
    }

    func flushPendingRealtimeMessagesForTesting() {
        flushPendingRealtimeMessages(reason: "testing")
    }
    #endif

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END

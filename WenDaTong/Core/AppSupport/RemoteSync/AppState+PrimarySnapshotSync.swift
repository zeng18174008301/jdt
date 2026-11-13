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
    @discardableResult
    func refreshRemoteSnapshot(silent: Bool, force: Bool = false) async -> Bool {
        var outcome = SyncFailureDiagnostic.PrimaryOutcome.missingSession
        defer { SyncFailureDiagnostic.persistPrimaryOutcome(outcome) }
        guard apiContext.hasIMSession else {
            bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            return false
        }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let syncPlan = remoteSyncEngine.remoteSnapshotSyncPlan(scope: scope, force: force)
        let syncCommand: RemoteSnapshotSyncCommand
        switch syncPlan {
        case .remoteSnapshot(let command):
            syncCommand = command
        case .skip:
            outcome = .skipped
            if force, !scope.isEmpty {
                pendingForcedRemoteSnapshotSuccessorScopes.insert(scope)
            }
            return false
        }
        let syncResult = remoteSyncEngine.beginRemoteSnapshotSync(syncCommand)
        guard syncResult.started else {
            outcome = .alreadyRunning
            if force, !scope.isEmpty {
                pendingForcedRemoteSnapshotSuccessorScopes.insert(scope)
            }
            return false
        }
        let performanceStart = CFAbsoluteTimeGetCurrent()
        let refreshSession = remoteSyncEngine.beginRemoteSnapshotRefresh()
        let generation = refreshSession.generation
        print("[JHT Perf] restore_start generation=\(generation) scope=\(Self.sessionScopeLogToken(scope))")
        defer {
            remoteSyncEngine.finishRemoteSnapshotSync(syncCommand)
            if remoteSyncEngine.finishRemoteSnapshotRefresh(refreshSession) {
                bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            }
            scheduleForcedRemoteSnapshotSuccessorIfNeeded(scope: scope)
        }
        // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_BEGIN
        if !silent {
            bootstrapPresentationStore.sync.syncFailureMessage = nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        }
        outcome = .obsolete
        switch await syncPrimaryConversationData(
            context: context, scope: scope, refreshSession: refreshSession, silent: silent,
            forceFull: force, performanceStart: performanceStart
        ) {
        case .stopped(let reason):
            outcome = reason
            return false
        case .finished(let primarySynced):
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return false }
            outcome = primarySynced ? .complete : .incomplete
            refreshSecondarySnapshotInBackground(context: context, scope: scope, refreshSession: refreshSession)
            return primarySynced
        }
    }
        // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_END
    private func scheduleForcedRemoteSnapshotSuccessorIfNeeded(scope: String) {
        guard pendingForcedRemoteSnapshotSuccessorScopes.remove(scope) != nil else {
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isCurrentRemoteScope(scope) else { return }
            _ = await self.refreshRemoteSnapshot(silent: true, force: true)
        }
    }
    // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_BEGIN
    private enum PrimaryConversationSyncResult {
        case finished(Bool)
        case stopped(SyncFailureDiagnostic.PrimaryOutcome)
    }

    private func syncPrimaryConversationData(
        context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession,
        silent: Bool, forceFull: Bool, performanceStart: CFAbsoluteTime
    ) async -> PrimaryConversationSyncResult {
        func incrementalFailureInterruption(
            _ error: Error, command: RemoteConversationSyncCommand, authority: IMAuthSessionFence,
            allowingAdvancedUnauthorized: Bool = false
        ) -> SyncFailureDiagnostic.PrimaryOutcome? {
            guard !command.replacesLocalSnapshot else { return nil }
            if Task.isCancelled || error is CancellationError { return .cancelled }
            guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return .obsolete }
            if apiContext.isSameAuthAuthority(as: authority) { return nil }
            // Only an ordinary 401 may reuse already-advanced credentials for the original single replay.
            if allowingAdvancedUnauthorized,
               case .unauthorized(let message) = error as? IMAPIError,
               message != DeviceRevocationDetector.logoutMessage,
               apiContext.credentialsAdvanced(since: authority) {
                return nil
            }
            return .authorityChanged
        }

        let command = remoteSyncEngine.remoteConversationSyncCommand(forceFull: forceFull || isConversationSnapshotPartial)
        let authority = context.authSessionFence
        do {
            return try await performPrimaryConversationSyncAttempt(
                context: context, scope: scope, refreshSession: refreshSession, command: command,
                performanceStart: performanceStart, authRefreshed: false
            )
        } catch {
            if let interruption = incrementalFailureInterruption(
                error, command: command, authority: authority, allowingAdvancedUnauthorized: true
            ) {
                return .stopped(interruption)
            }
            if error is CancellationError { SyncFailureDiagnostic.persistPrimaryOutcome(.cancelled) }
            guard !(error is CancellationError), isCurrentRemoteRefresh(refreshSession, scope: scope) else {
                return .finished(false)
            }
            if isRefreshableSessionError(error),
               await refreshStoredAuthSessionIfNeeded(reason: "primary_sync", silent: silent, context: context, scope: scope) {
                if !command.replacesLocalSnapshot, Task.isCancelled { return .stopped(.cancelled) }
                let refreshedContext = apiContext
                let refreshedScope = remoteDataScopeKey(for: refreshedContext)
                guard refreshedContext.hasIMSession,
                      refreshedScope == scope,
                      isCurrentRemoteRefresh(refreshSession, scope: scope) else { return .finished(false) }
                let replayCommand = remoteSyncEngine.remoteConversationSyncCommand(
                    forceFull: forceFull || isConversationSnapshotPartial
                )
                let replayAuthority = refreshedContext.authSessionFence
                do {
                    return try await performPrimaryConversationSyncAttempt(
                        context: refreshedContext, scope: scope, refreshSession: refreshSession, command: replayCommand,
                        performanceStart: performanceStart, authRefreshed: true
                    )
                } catch {
                    if let interruption = incrementalFailureInterruption(error, command: replayCommand, authority: replayAuthority) {
                        return .stopped(interruption)
                    }
                    if error is CancellationError { SyncFailureDiagnostic.persistPrimaryOutcome(.cancelled) }
                    guard !(error is CancellationError), isCurrentRemoteRefresh(refreshSession, scope: scope) else {
                        return .finished(false)
                    }
                    handlePrimaryConversationSyncFailure(error, silent: silent)
                    return .finished(false)
                }
            }
            if let interruption = incrementalFailureInterruption(error, command: command, authority: authority) {
                return .stopped(interruption)
            }
            handlePrimaryConversationSyncFailure(error, silent: silent)
            return .finished(false)
        }
    }

    private func performPrimaryConversationSyncAttempt(
        context: IMAPIContext,
        scope: String,
        refreshSession: RemoteSnapshotRefreshSession,
        command: RemoteConversationSyncCommand,
        performanceStart: CFAbsoluteTime,
        authRefreshed: Bool
    ) async throws -> PrimaryConversationSyncResult {
        if command.replacesLocalSnapshot {
            return .finished(try await performPagedConversationSnapshot(
                context: context, scope: scope, refreshSession: refreshSession,
                command: command, performanceStart: performanceStart
            ))
        }
        let diagnostic = SyncFailureDiagnostic.HTTPObservation(.conversationSync)
        let data = try await SyncFailureDiagnostic.$httpObservation.withValue(diagnostic) {
            defer { diagnostic.finish() }
            return try await diagnostic.perform {
                try await api.syncConversations(context: context, version: command.requestedVersion)
            }
        }
        try Task.checkCancellation()
        guard isCurrentRemoteRefresh(refreshSession, scope: scope) else { return .stopped(.obsolete) }
        guard apiContext.isSameAuthAuthority(as: context.authSessionFence),
              apiContext.deviceID == context.deviceID else { return .stopped(.authorityChanged) }
        let generation = refreshSession.generation
        remoteSyncEngine.finishRemoteConversationSync(command, responseVersion: data.version)
        let applyStart = CFAbsoluteTimeGetCurrent()
        applyRemoteConversations(data.conversations, replacing: command.replacesLocalSnapshot)
        applySearchInvalidations(data.removedConversations.map {
            SearchInvalidationEvent(removedConversation: $0, fallbackTenantID: context.tenantID ?? "")
        })
        logConversationSyncSummary(data: data, requestedVersion: command.requestedVersion, generation: generation, authRefreshed: authRefreshed)
        let applyMs = Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000)
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        lastRemoteSnapshotPrimarySyncedAt = Date()
        bootstrapPresentationStore.sync.syncFailureMessage = nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        let listReadyMs = Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)
        if authRefreshed {
            print("[JHT Perf] conversation_list_ready_ms=\(listReadyMs) count=\(data.conversations.count) apply_ms=\(applyMs) generation=\(generation) auth_refreshed=true")
        } else {
            print("[JHT Perf] conversation_list_ready_ms=\(listReadyMs) count=\(data.conversations.count) apply_ms=\(applyMs) generation=\(generation)")
        }
        startConversationHistoryPrefetch(
            data.conversations,
            context: context,
            scope: scope,
            refreshSession: refreshSession,
            performanceStart: performanceStart
        )
        schedulePersistedMessageSequenceRecoveries(reason: "remote_snapshot")
        scheduleRemoteSnapshotCacheWrite(
            scope: scope,
            source: .conversationSync,
            replaceMissingConversations: command.replacesLocalSnapshot
        )
        return .finished(true)
    }
    // WDT_IOS1_TYPED_INCREMENTAL_CONVERSATION_DECODE_20261111_END
    func makeConversationUserLookup() -> ConversationUserLookup {
        ConversationUserLookup(currentUser: currentUser, currentIdentifiers: currentUserIdentitySet(),
                               contacts: contacts, groupMembers: groups.flatMap(\.members))
    }

    private func indexedConversationRows(_ rows: [ConversationMessageSnapshot]) -> [String: ConversationMessageSnapshot] {
        let lookup = makeConversationUserLookup()
        var result: [String: ConversationMessageSnapshot] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let channelID = remoteChannelID(for: row, lookup: lookup)
            if result[channelID] == nil { result[channelID] = row }
        }
        return result
    }

    private func performPagedConversationSnapshot(
        context: IMAPIContext, scope: String, refreshSession: RemoteSnapshotRefreshSession,
        command: RemoteConversationSyncCommand, performanceStart: CFAbsoluteTime
    ) async throws -> Bool {
        func currentRows() -> [String: ConversationMessageSnapshot] {
            indexedConversationRows(conversationStore.conversationMessageSnapshots())
        }
        var authority = ConversationPageAuthority(context: context)
        func validate() throws {
            let currentRefresh = isCurrentRemoteRefresh(refreshSession, scope: scope)
            guard currentRefresh else {
                SyncFailureDiagnostic.persistPrimaryOutcome(.obsolete)
                throw CancellationError()
            }
            do {
                try authority.validate(current: apiContext)
            } catch {
                if error is CancellationError, !Task.isCancelled {
                    SyncFailureDiagnostic.persistPrimaryOutcome(.authorityChanged)
                } else if let failure = error as? ConversationPageFailure,
                          failure.code == "conversation_page_credentials_advanced" {
                    SyncFailureDiagnostic.persistPrimaryOutcome(.credentialsAdvanced)
                }
                throw error
            }
        }
        var presentation = ConversationSnapshotPresentation(current: currentRows())
        let pagePresentationID = UUID()
        // Observe mutations as they happen, including a toggle/read/delete that
        // changes back before the next page arrives (value comparison alone loses it).
        // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_BEGIN
        let changes = conversationStore.memoryCommits.sink { commit in
            let current = currentRows()
            if commit.presentationPageID == pagePresentationID {
                // Page notifications precede any queued local command. Attribute
                // exactly this frame before observing local reentrant mutations.
                let previous = commit.previous.conversations.map { row in
                    ConversationMessageSnapshot(conversation: row,
                        messages: commit.messageChanges[row.id]?.previous
                            ?? self.conversationStore.messageMemoryStore.messages(for: row.id))
                }
                presentation.didApply([], current: current, previous: self.indexedConversationRows(previous))
            } else {
                presentation.observe(current: current)
            }
        }
        // WDT_IOS1_SERIAL_MEMORY_NOTIFICATIONS_20261110_END
        defer { changes.cancel() }
        var firstPage = true
        var prefetchRemotes: [RemoteConversation] = []
        bootstrapPresentationStore.sync.isLoadingMoreConversations = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isConversationSnapshotPartial = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        defer {
            if isCurrentRemoteRefresh(refreshSession, scope: scope) {
                bootstrapPresentationStore.sync.isLoadingMoreConversations = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            }
        }
        let version = try await ConversationPageLoader.load(
            request: { cursor in
                let diagnostic = SyncFailureDiagnostic.HTTPObservation(.conversationPage)
                let page = try await SyncFailureDiagnostic.$httpObservation.withValue(diagnostic) {
                    defer { diagnostic.finish() }
                    return try await diagnostic.perform {
                        try await self.api.conversationPage(context: authority.context, cursor: cursor)
                    }
                }
                try await self.waitForConversationListInteractionToEnd(scope: scope)
                return page
            },
            validate: validate,
            onPage: { page in
                let lookup = self.makeConversationUserLookup()
                let current = currentRows()
                let accepted = self.canonicalRemoteConversations(page.conversations, lookup: lookup).filter { remote in
                    let key = self.normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType, lookup: lookup)
                    let unchanged = presentation.accept(key, current: current)
                    // A page may contain an older server summary than an already
                    // received local message, even before this refresh began.
                    return unchanged && (current[key]?.lastMsgSeq ?? 0) <= self.remoteConversationLatestSeq(remote)
                }
                self.conversationStore.performMemoryCommand(presentationPageID: pagePresentationID) {
                    self.applyRemoteConversations(accepted, replacing: false)
                }
                presentation.didApply(accepted.map {
                    self.normalizedRemoteChannelID($0.channelID, channelType: $0.channelType, lookup: lookup)
                }, current: currentRows(), previous: current) // WDT_IOS1_REFACTOR_PAGED_COMMIT_EXPECTATIONS_20261110
                self.bootstrapPresentationStore.sync.isInitialDataLoading = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                if firstPage {
                    firstPage = false
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - performanceStart) * 1000)
                    print("[JHT Perf] conversation_first_page_ready_ms=\(elapsed) count=\(page.conversations.count)")
                    prefetchRemotes = page.conversations
                }
            },
            onRestart: {
                // Retire this attempt's unchanged presentation before accepting
                // a new snapshot. Concurrent local/realtime changes survive.
                // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：分页快照重启时仅在会话数组变化后发布
                self.conversationStore.performMemoryCommand(presentationPageID: pagePresentationID) {
                    self.conversationStore.replaceConversationsIfChanged(
                        Array(presentation.restarting(current: currentRows()).values)
                            .sorted(by: self.conversationStore.conversationListPrecedes),
                        reason: "paged_snapshot_restart"
                    )
                }
                // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束
                firstPage = true
                prefetchRemotes = []
            }
        )
        try validate()
        changes.cancel()
        // JHT_MOD_BEGIN CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改开始：分页快照完成时避免发布完全相同的会话数组
        conversationStore.replaceConversationsIfChanged(
            Array(presentation.completing(current: currentRows()).values)
                .sorted(by: conversationStore.conversationListPrecedes),
            reason: "paged_snapshot_complete"
        )
        // JHT_MOD_END CONVERSATION_LIST_SKIP_UNCHANGED_PUBLISH_20260912 - 修改结束
        remoteSyncEngine.finishRemoteConversationSync(command, responseVersion: version)
        bootstrapPresentationStore.sync.hasLoadedRemoteSnapshot = true // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        bootstrapPresentationStore.sync.isConversationSnapshotPartial = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        lastRemoteSnapshotPrimarySyncedAt = Date()
        bootstrapPresentationStore.sync.syncFailureMessage = nil // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        startConversationHistoryPrefetch(
            prefetchRemotes, context: authority.context, scope: scope,
            refreshSession: refreshSession, performanceStart: performanceStart
        )
        schedulePersistedMessageSequenceRecoveries(reason: "remote_snapshot")
        scheduleRemoteSnapshotCacheWrite(scope: scope, source: .conversationSync, replaceMissingConversations: true)
        return true
    }

    private func handlePrimaryConversationSyncFailure(_ error: Error, silent: Bool) {
        recordSyncFailureDiagnostic(error, endpoint: isConversationSnapshotPartial ? .conversationPage : .conversationSync)
        applySyncFailure(error, silent: silent)
        // A data-plane 401 only proves that this access token was rejected. The
        // refresh endpoint remains the authority for terminal session state.
        // `refreshStoredAuthSessionIfNeeded` has already handled an authoritative
        // expired/revoked/reused response before this fallback is reached.
        if !isUnauthorizedError(error), workspaceAccessCode(from: error) != nil {
            handleRemoteError(error, fallback: "聊天记录同步失败", silent: silent)
        }
    }

    private func logConversationSyncSummary(data: RemoteConversationSyncData, requestedVersion: Int64, generation: Int, authRefreshed: Bool = false) {
        let topConversation = conversationStore.conversationMessageSnapshots().first
        let topID: String
        if let topConversation {
            let channelID = remoteChannelID(for: topConversation)
            if topConversation.kind == .direct {
                let sum = channelID.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
                topID = "direct#\(abs(sum % 100_000))"
            } else {
                topID = channelID
            }
        } else {
            topID = "none"
        }
        let topTitle = topConversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latestAt = Int(topConversation?.sortTimestamp ?? 0)
        let latestSeq = topConversation?.lastMsgSeq ?? 0
        print("[JHT Perf] conversations_sync requestedVersion=\(requestedVersion) responseVersion=\(data.version) remoteCount=\(data.conversations.count) localCount=\(conversationStore.conversations.count) topConversation=\(topID) topTitle=\(topTitle) latestSeq=\(latestSeq) latestAt=\(latestAt) authRefreshed=\(authRefreshed) generation=\(generation)")
    }

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

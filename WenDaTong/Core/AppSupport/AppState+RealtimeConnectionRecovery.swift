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
    func realtimeConnectionRequest(context: IMAPIContext) -> RealtimeConnectionRequest? {
        let fallbackURL = api.webSocketURL(context: context)
		if let routed = (api as? IMAPIClient)?.runtimeRealtimeConnectionRequest(context: context) {
			recordAccessDiagnosticsRealtimeRequest(routed, context: context)
			return routed
		}
        let request = accessDiscovery.realtimeConnectionRequest(
            context: context,
            token: context.imToken ?? "",
            fallbackURL: fallbackURL,
            quicConfiguration: RealtimeQUICConfiguration.load()
        )
        recordAccessDiagnosticsRealtimeRequest(request, context: context)
        DebugConsoleDiagnostics.trace("[JHT Realtime] request url=\(redactedRealtimeURLSummary(request?.url)) fallback=\(redactedRealtimeURLSummary(fallbackURL)) local_fallback=\(Self.isLocalRealtimeFallbackURL(fallbackURL)) quic=\(request?.quicRequest != nil)")
        return request
    }

    func scheduleAccessDiscoveryRefresh(context: IMAPIContext, reason: String, force: Bool = false) {
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        Task { [weak self] in
            guard let self,
                  self.isCurrentRemoteScope(scope) else {
                return
            }
            let outcome = await self.refreshAccessDiscoverySingleFlight(
                context: context,
                scope: scope,
                force: force
            )
            self.recordAccessDiagnosticsDiscoveryOutcome(outcome)
        }
    }

    private func refreshAccessDiscoverySingleFlight(
        context: IMAPIContext,
        scope: String,
        force: Bool
    ) async -> AccessDiscoveryRefreshOutcome {
        if accessDiscoveryRefreshScope == scope, let existing = accessDiscoveryRefreshTask {
            return await existing.value
        }
        recordAccessDiagnosticsDiscoveryFetching(context: context)
        let task = Task { @MainActor [weak self] in
            guard let self, self.isCurrentRemoteScope(scope) else {
                return AccessDiscoveryRefreshOutcome.unavailable
            }
            return await self.accessDiscovery.refresh(
                context: context,
                fetcher: self.api,
                force: force
            )
        }
        accessDiscoveryRefreshScope = scope
        accessDiscoveryRefreshTask = task
        let outcome = await task.value
        if accessDiscoveryRefreshScope == scope {
            accessDiscoveryRefreshTask = nil
            accessDiscoveryRefreshScope = nil
        }
        return outcome
    }

    func startRealtimeConnection(context: IMAPIContext? = nil) {
        let context = context ?? apiContext
        guard iosRiskTelemetrySceneIsActive else {
            (realtimeClient as? RealtimeClient)?.recordAdmissionDiagnostic(.sceneInactive)
            return
        }
        guard isAuthenticated else {
            (realtimeClient as? RealtimeClient)?.recordAdmissionDiagnostic(.notAuthenticated)
            return
        }
        guard context.hasIMSession else {
            (realtimeClient as? RealtimeClient)?.recordAdmissionDiagnostic(.missingSession)
            return
        }
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        if !usesLocalRealtimeFallback(context: context) {
            // A validated restored runtime route or the API client's configured
            // session fallback can resume immediately. Refresh discovery in
            // parallel so the first active scene cannot remain offline merely
            // because discovery is slow or temporarily unavailable.
            let hasImmediateRoute = (api as? IMAPIClient)?.runtimeRealtimeConnectionRequest(context: context) != nil
                || api.webSocketURL(context: context) != nil
            if hasImmediateRoute {
                startRealtimeConnectionAfterDiscovery(context: context)
                scheduleAccessDiscoveryRefresh(context: context, reason: "restored_realtime_start")
                return
            }
            if accessDiscoveryRealtimeStartScope == scope,
               accessDiscoveryRealtimeStartTask != nil {
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.accessDiscoveryRealtimeStartScope == scope {
                        self.accessDiscoveryRealtimeStartTask = nil
                        self.accessDiscoveryRealtimeStartScope = nil
                    }
                }
                let outcome = await self.refreshAccessDiscoverySingleFlight(
                    context: context,
                    scope: scope,
                    force: false
                )
                self.recordAccessDiagnosticsDiscoveryOutcome(outcome)
                guard self.iosRiskTelemetrySceneIsActive,
                      self.isAuthenticated,
                      self.isCurrentRemoteScope(scope),
                      context.hasIMSession else {
                    return
                }
                self.startRealtimeConnectionAfterDiscovery(context: context)
            }
            accessDiscoveryRealtimeStartScope = scope
            accessDiscoveryRealtimeStartTask = task
            return
        }
        startRealtimeConnectionAfterDiscovery(context: context)
    }

    private func startRealtimeConnectionAfterDiscovery(context: IMAPIContext) {
        guard let request = realtimeConnectionRequest(context: context) else {
            (realtimeClient as? RealtimeClient)?.recordAdmissionDiagnostic(.routeUnavailable)
            #if DEBUG
            if authPolicyScreenshotModeEnabled { return }
            #endif
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("实时连接地址不可用")
            return
        }
        realtimeClient.start(request: request)
    }

    func disconnectRealtime(shouldReconnect: Bool) {
        if !shouldReconnect {
            clearPendingRealtimeMessages(reason: "disconnect")
            activeRealtimeConversationRecoveryTask?.cancel()
            activeRealtimeConversationRecoveryTask = nil
            accessDiscoveryRealtimeStartTask?.cancel()
            accessDiscoveryRealtimeStartTask = nil
            accessDiscoveryRealtimeStartScope = nil
        }
        invalidateRealtimeEndpointStableConfirmation()
        realtimeClient.disconnect(shouldReconnect: shouldReconnect)
        if !shouldReconnect {
            clearRealtimeReconnectNotice()
        }
    }

    func scheduleRealtimeEndpointStableConfirmation() {
        realtimeStableConnectionGeneration += 1
        let generation = realtimeStableConnectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + realtimeEndpointStableConfirmationDelay) { [weak self] in
			guard let self,
			      self.realtimeStableConnectionGeneration == generation,
			      self.isRealtimeConnected else {
				return
			}
			if let api = self.api as? IMAPIClient {
				if api.completeRuntimeRealtimePreferredProbe(context: self.apiContext) {
					self.accessDiscovery.markActiveRealtimeEndpointSucceeded()
					return
				}
				if api.prepareRuntimeRealtimePreferredProbe(context: self.apiContext) {
					self.realtimeClient.disconnect(shouldReconnect: true)
					return
				}
			}
            self.accessDiscovery.markActiveRealtimeEndpointSucceeded()
        }
    }

    func invalidateRealtimeEndpointStableConfirmation() {
        realtimeStableConnectionGeneration += 1
    }

    func scheduleRealtimeReconnectToastIfNeeded() {
        guard realtimeReconnectNoticeTask == nil else { return }
        let scope = remoteDataScopeKey(for: apiContext)
        let delayNanoseconds = realtimeReconnectNoticeDelayNanoseconds
        realtimeReconnectNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.realtimeReconnectNoticeTask = nil
                guard self.isAuthenticated,
                      self.apiContext.hasIMSession,
                      self.isCurrentRemoteScope(scope),
                      !self.isRealtimeConnected else {
                    return
                }
                self.showRealtimeReconnectToastIfNeeded()
            }
        }
    }

    private func showRealtimeReconnectToastIfNeeded() {
        let now = Date()
        guard remoteSyncEngine.realtimeReconnectNoticePlan(now: now, throttleInterval: realtimeReconnectNoticeThrottleInterval) == .show else {
            return
        }
        remoteSyncEngine.rememberRealtimeReconnectNoticeShown(at: now)
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("实时连接中断，正在重连")
    }

    func clearRealtimeReconnectNotice() {
        realtimeReconnectNoticeTask?.cancel()
        realtimeReconnectNoticeTask = nil
        remoteSyncEngine.clearRealtimeReconnectNotice()
        if toast == "实时连接中断，正在重连" {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
        }
    }

    func scheduleRealtimeRecoveryRefresh(reason: String) {
        flushPendingRealtimeMessagesIfNeeded(reason: "before_recovery_refresh_\(reason)")
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated, context.hasIMSession, isCurrentRemoteScope(scope) else { return }
        enqueueActiveRealtimeRecoveryConversation()
        let refreshPlan = remoteSyncEngine.realtimeRecoveryRefreshPlan(
            reason: reason,
            now: Date(),
            throttleInterval: 8
        )
        guard case .refresh(let command) = refreshPlan else {
            flushRealtimeRecoveryConversations(reason: reason)
            return
        }
        let syncResult = remoteSyncEngine.beginRealtimeRecoveryRefresh(command)
        guard syncResult.started else {
            flushRealtimeRecoveryConversations(reason: reason)
            return
        }
        let syncEngine = remoteSyncEngine
        guard syncEngine.claimRealtimeRecoveryTask(.refresh) else {
            syncEngine.finishRealtimeRecoveryRefresh(command)
            flushRealtimeRecoveryConversations(reason: reason)
            return
        }
        let task = Task { @MainActor [weak self, syncEngine] in
            defer {
                syncEngine.finishRealtimeRecoveryRefresh(command)
                syncEngine.finishRealtimeRecoveryTask(.refresh)
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.isAuthenticated,
                  self.isCurrentRemoteScope(scope) else { return }
            let refreshStart = Date()
            if self.shouldSkipRealtimeRecoverySnapshotForRecentPrimarySync(
                reason: reason,
                now: refreshStart
            ) {
                self.remoteSyncEngine.rememberRealtimeRecoveryRefresh(at: refreshStart)
                self.flushRealtimeRecoveryConversations(reason: reason)
                return
            }
            self.remoteSyncEngine.rememberRealtimeRecoveryRefresh(at: refreshStart)
            _ = await self.refreshRemoteSnapshot(silent: true, force: true)
            guard self.isCurrentRemoteScope(scope) else { return }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            await self.refreshRTCSignalingSilently(context: context, scope: scope)
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            guard self.isCurrentRemoteScope(scope) else { return }
            self.flushRealtimeRecoveryConversations(reason: reason)
            DebugConsoleDiagnostics.trace("[JHT Perf] realtime_recovery_refresh reason=\(reason)")
        }
        syncEngine.attachRealtimeRecoveryTask(.refresh, task: task)
    }

    private func shouldSkipRealtimeRecoverySnapshotForRecentPrimarySync(reason: String, now: Date) -> Bool {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedReason == "connect_ack" || normalizedReason == "reconnect" else {
            return false
        }
        let snapshot = RemoteSnapshotSyncCommand(scope: remoteDataScopeKey(for: apiContext))
        if remoteSyncEngine.isInFlight(snapshot.request) {
            return true
        }
        guard let lastRemoteSnapshotPrimarySyncedAt else { return false }
        let age = now.timeIntervalSince(lastRemoteSnapshotPrimarySyncedAt)
        guard age >= 0,
              age < realtimeRecoveryRecentSnapshotCooldownSeconds else {
            return false
        }
        DebugConsoleDiagnostics.trace("[JHT Perf] realtime_recovery_refresh_skip reason=\(normalizedReason) gate=recent_snapshot age_ms=\(Int(age * 1000))")
        return true
    }

    func scheduleActiveConversationRecoveryAfterRealtimeConnected(reason: String) {
        let conversationID = activeRealtimeConversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !conversationID.isEmpty else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated,
              context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        activeRealtimeConversationRecoveryTask?.cancel()
        activeRealtimeConversationRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isAuthenticated,
                  self.isRealtimeConnected,
                  self.isCurrentRemoteScope(scope),
                  self.activeRealtimeConversationID == conversationID else {
                return
            }
            if !self.shouldSkipRealtimeRecoverySnapshotForRecentPrimarySync(reason: "connect_ack", now: Date()) {
                _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                guard !Task.isCancelled,
                      self.isCurrentRemoteScope(scope),
                      self.activeRealtimeConversationID == conversationID else {
                    return
                }
            }
            self.syncConversationMessagesIfNeeded(
                conversationID,
                force: true,
                silent: true,
                showLoadingIndicator: false,
                trimToLatestWindow: true
            )
            self.activeRealtimeConversationRecoveryTask = nil
            DebugConsoleDiagnostics.trace("[JHT Perf] realtime_active_conversation_recovery reason=\(reason)")
        }
    }

    func scheduleRealtimeRecoveryConversationSync(_ conversationID: String?, reason: String) {
        flushPendingRealtimeMessagesIfNeeded(reason: "before_recovery_conversation_\(reason)")
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated, context.hasIMSession, isCurrentRemoteScope(scope) else { return }
        let syncEngine = remoteSyncEngine
        guard syncEngine.enqueueRealtimeRecoveryConversation(conversationID) else { return }
        guard syncEngine.claimRealtimeRecoveryTask(.conversationFlush) else { return }
        let task = Task { @MainActor [weak self, syncEngine] in
            defer {
                syncEngine.finishRealtimeRecoveryTask(.conversationFlush)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.isAuthenticated,
                  self.isCurrentRemoteScope(scope) else { return }
            self.flushRealtimeRecoveryConversations(reason: reason)
        }
        syncEngine.attachRealtimeRecoveryTask(.conversationFlush, task: task)
    }

    private func enqueueActiveRealtimeRecoveryConversation() {
        guard let activeRealtimeConversationID else { return }
        _ = remoteSyncEngine.enqueueRealtimeRecoveryConversation(activeRealtimeConversationID)
    }

    private func flushRealtimeRecoveryConversations(reason: String) {
        let conversationIDs = remoteSyncEngine.drainRealtimeRecoveryConversations()
        guard !conversationIDs.isEmpty else { return }
        for conversationID in conversationIDs {
            if let target = messageSequenceRecoveryTargets[conversationID] {
                syncMessageSequenceRecovery(
                    conversationID: conversationID,
                    target: target,
                    reason: reason
                )
            } else {
                syncConversationMessagesIfNeeded(conversationID, force: true, silent: true)
            }
        }
        DebugConsoleDiagnostics.trace("[JHT Perf] realtime_recovery_conversations reason=\(reason) count=\(conversationIDs.count)")
    }

}

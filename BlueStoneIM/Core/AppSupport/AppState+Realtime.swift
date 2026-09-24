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

// MARK: - Realtime

extension AppState {
    func iosRiskTelemetryBind(windowScene: UIWindowScene?) {
        iosSceneCaptureMonitor.onChange = { [weak self] isCaptured in
            self?.iosRiskCaptureStateChanged(isCaptured: isCaptured)
        }
        iosSceneCaptureMonitor.bind(windowScene: windowScene)
    }

    func iosRiskTelemetrySceneDidBecomeAvailable(isActive: Bool) {
		(api as? IMAPIClient)?.runtimeColdLaunchSceneDidBecomeAvailable(isActive: isActive)
        iosRiskTelemetrySceneIsActive = isActive
        if isActive {
            syncIOSRiskTelemetrySession()
        } else {
            iosRiskTelemetry.sceneDidBecomeInactive()
        }
    }

    func iosRiskScreenshotDetected() {
        syncIOSRiskTelemetrySession()
        iosRiskTelemetry.recordScreenshot()
    }

    func iosRiskCaptureStateChanged(isCaptured: Bool) {
        syncIOSRiskTelemetrySession(captureIsActive: isCaptured)
    }

    func scheduleIOSRiskTelemetryContextSync() {
        iosRiskTelemetryContextSyncTask?.cancel()
        iosRiskTelemetryContextSyncTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.iosRiskTelemetryContextSyncTask = nil
            self.syncIOSRiskTelemetrySession()
        }
    }

    func syncIOSRiskTelemetrySession(captureIsActive: Bool? = nil) {
        iosRiskTelemetryContextSyncTask?.cancel()
        iosRiskTelemetryContextSyncTask = nil
        iosRiskTelemetry.updateSession(
            context: apiContext,
            isAuthenticated: isAuthenticated,
            memberRole: currentEnterprise.role,
            sceneIsActive: iosRiskTelemetrySceneIsActive,
            captureIsActive: captureIsActive ?? iosSceneCaptureMonitor.currentIsCaptured
        )
    }

    func appDidBecomeInactive() {
		(api as? IMAPIClient)?.runtimeColdLaunchSceneDidBecomeInactive()
        // Invalidate grants already held by protected views. Do not invalidate the stable
        // authorization identity used by a Face ID prompt that caused this transition.
        biometricAccessRevision &+= 1
        revokeBiometricProtectedAccess()
        iosRiskTelemetry.sceneDidBecomeInactive()
        iosRiskTelemetrySceneIsActive = false
        renderCallPromptEnvironment(.applicationDidEnterBackground)
    }

    func appDidEnterForeground() {
		(api as? IMAPIClient)?.runtimeColdLaunchSceneDidBecomeAvailable(isActive: true)
        isApplicationBackgroundedForRTC = false
        // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log unlock/foreground boundaries for RTC interface diagnosis only.
        logRTCLifecycleInterfaceEvent("foreground_unlock")
        // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
        renderCallPromptEnvironment(.applicationDidBecomeActive)
        #if DEBUG
        if licenseQuotaScreenshotScenario != nil {
            return
        }
        #endif
        iosRiskTelemetrySceneIsActive = true
        syncIOSRiskTelemetrySession()
        flushPendingRealtimeMessagesIfNeeded(reason: "foreground")
        Task { [weak self] in
            _ = await self?.refreshCurrentAppPolicyAndDepartmentRuntime(reason: "foreground", force: true)
        }
        restartForegroundAuthSessionRefreshScheduler()
        guard isAuthenticated else { return }
        evaluateForegroundSplashOverlayIfNeeded()
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        GroupForegroundSessionClearDiagnostics.begin(
            context: context,
            scopeCurrent: isCurrentRemoteScope(scope),
            postAuthenticated: isAuthenticated
        )
        #endif
        voiceDebug("foreground context=\(Self.rtcDebugContextSummary(context))")
        resumeRTCMediaStateHeartbeatAfterForeground()
        Task {
            guard isCurrentRemoteScope(scope) else { return }
            _ = await refreshStoredAuthSessionIfNeeded(reason: "foreground", silent: true, context: context, scope: scope)
            // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: foreground tenant sessions also keep platform access token fresh for workspace APIs.
            if context.hasIMSession {
                _ = await refreshPlatformAuthSessionIfNeeded(reason: "foreground_platform", silent: true, context: apiContext)
            }
            // WDT_IOS_TOKEN_VALIDITY_20260924_END
            #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
            GroupForegroundSessionClearDiagnostics.recordPostDecision(
                scopeCurrent: isCurrentRemoteScope(scope),
                postAuthenticated: isAuthenticated,
                context: apiContext
            )
            #endif
            let refreshedContext = apiContext
            let refreshedScope = remoteDataScopeKey(for: refreshedContext)
            guard refreshedContext.hasIMSession,
                  isCurrentRemoteScope(refreshedScope) else { return }
            // Realtime must bind only after the foreground refresh attempt has
            // either committed the rotated token or proved temporarily
            // unavailable while preserving the durable session.
            startRealtimeConnection(context: refreshedContext)
            if let ticket = localMessageTicket {
                await recoverDurableOutbox(ticket: ticket, scope: refreshedScope)
                scheduleDurableReadAckRecovery(ticket: ticket, runImmediately: true)
            }
            // JHT_MOD_BEGIN ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改开始：回前台后静默恢复锁屏期间中断的图片/文件发送
            resumePendingAttachmentUploadsAfterForeground(scope: refreshedScope)
            // JHT_MOD_END ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改结束
            registerPendingStandardPushDeviceIfPossible(reason: "foreground")
            registerPendingVoIPDeviceIfPossible(reason: "foreground")
            _ = await refreshCurrentEnterpriseProfile(silent: true)
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard !isApplicationBackgroundedForRTC else { return }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            startRTCCallRefreshLoop()
            scheduleRealtimeRecoveryRefresh(reason: "foreground")
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            await refreshRTCSignalingSilently(context: refreshedContext, scope: refreshedScope)
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard !isApplicationBackgroundedForRTC,
                  isCurrentRemoteScope(refreshedScope) else { return }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            if let activeRealtimeConversationID {
                syncConversationMessagesIfNeeded(activeRealtimeConversationID, force: true, silent: true)
            }
        }
    }

    func appDidEnterBackground() {
		(api as? IMAPIClient)?.runtimeColdLaunchSceneDidEnterBackground()
        #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        GroupForegroundSessionClearDiagnostics.suspend()
        #endif
        biometricAccessRevision &+= 1
        revokeBiometricProtectedAccess()
        isApplicationBackgroundedForRTC = true
        // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log lock/background boundaries for RTC interface diagnosis only.
        logRTCLifecycleInterfaceEvent("background_lock")
        // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
        iosRiskTelemetry.sceneDidEnterBackground()
        iosRiskTelemetrySceneIsActive = false
        // JHT_MOD_BEGIN ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改开始：后台暂停图片/文件上传 task，保留 pending/outbox 供前台继续
        suspendPendingAttachmentUploadsForBackground()
        // JHT_MOD_END ATTACHMENT_FOREGROUND_RESUME_20260912 - 修改结束
        if isAuthenticated, apiContext.hasIMSession {
            scheduleLocalMutationSnapshotCacheWriteForVisibleConversations(
                scope: remoteDataScopeKey(for: apiContext)
            )
        }
        foregroundAuthSessionRefreshSchedulerTask?.cancel()
        foregroundAuthSessionRefreshSchedulerTask = nil
        durableOutboxRecoveryTask?.cancel()
        durableOutboxRecoveryTask = nil
        durableReadAckRecoveryTask?.cancel()
        durableReadAckRecoveryRestartRequested = false
        renderCallPromptEnvironment(.applicationDidEnterBackground)
        clearPendingRealtimeMessages(reason: "background")
        if let scope = splashTenantScope(for: apiContext) {
            SplashSnapshotStore.recordBackgrounded(scope: scope)
        }
        splashConfigurationRefreshTask?.cancel()
        splashConfigurationRefreshTask = nil
        splashConfigurationRefreshGeneration.invalidate()
        didEvaluateInitialSplashOverlay = true
        pendingInitialSplashOverlayEvaluation = false
        initialSplashOverlayEvaluationStartedAt = nil
        didPresentSplashInCurrentActivation = false
        dismissSplashOverlay(reason: "background", cancelTask: true)
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
    }

    private func restartForegroundAuthSessionRefreshScheduler() {
        foregroundAuthSessionRefreshSchedulerTask?.cancel()
        foregroundAuthSessionRefreshSchedulerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.iosRiskTelemetrySceneIsActive {
                guard self.isAuthenticated,
                      self.apiContext.hasRefreshSession else {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(
                                IMAuthSessionPreemptiveRefreshPolicy.inactiveSessionDiscoverySeconds
                                    * 1_000_000_000
                            )
                        )
                    } catch {
                        return
                    }
                    continue
                }

                let context = self.apiContext
                // WDT_IOS_TOKEN_VALIDITY_20260924_BEGIN: Android keeps account/platform and tenant tokens independently fresh.
                if context.hasIMSession {
                    _ = await self.refreshPlatformAuthSessionIfNeeded(
                        reason: "foreground_platform_preemptive",
                        silent: true,
                        context: context
                    )
                }
                // WDT_IOS_TOKEN_VALIDITY_20260924_END
                let accessExpiresAt = IMAuthSessionPreemptiveRefreshPolicy.activeAccessExpiresAt(
                    hasIMSession: context.hasIMSession,
                    contextAccessExpiresAt: context.accessExpiresAt,
                    tenantAccessExpiresAt: context.tenantAuthSession?.accessExpiresAt ?? 0,
                    platformAccessExpiresAt: context.platformAuthSession?.accessExpiresAt ?? 0,
                    legacyIMAccessExpiresAt: IMTenantIMTokenExpiryStore.load()
                )
                guard let refreshDelay = IMAuthSessionPreemptiveRefreshPolicy.delayUntilRefresh(
                    accessExpiresAt: accessExpiresAt,
                    now: Date().timeIntervalSince1970
                ) else {
                    // Older, backward-compatible servers may omit the optional
                    // access expiry. Keep discovering metadata without rotating
                    // blindly; an actual 401 still enters the same singleflight.
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(
                                IMAuthSessionPreemptiveRefreshPolicy.maximumClockRecheckSeconds
                                    * 1_000_000_000
                            )
                        )
                    } catch {
                        return
                    }
                    continue
                }

                let boundedDelay = IMAuthSessionPreemptiveRefreshPolicy.boundedSleepSeconds(for: refreshDelay)
                if boundedDelay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(boundedDelay * 1_000_000_000))
                    } catch {
                        return
                    }
                    continue
                }

                let scope = context.hasIMSession ? self.remoteDataScopeKey(for: context) : ""
                let refreshed = await self.refreshStoredAuthSessionIfNeeded(
                    reason: "foreground_preemptive",
                    silent: true,
                    context: context,
                    scope: scope
                )
                guard !Task.isCancelled, self.iosRiskTelemetrySceneIsActive else { return }
                let nextAccessExpiresAt = IMAuthSessionPreemptiveRefreshPolicy.activeAccessExpiresAt(
                    hasIMSession: self.apiContext.hasIMSession,
                    contextAccessExpiresAt: self.apiContext.accessExpiresAt,
                    tenantAccessExpiresAt: self.apiContext.tenantAuthSession?.accessExpiresAt ?? 0,
                    platformAccessExpiresAt: self.apiContext.platformAuthSession?.accessExpiresAt ?? 0,
                    legacyIMAccessExpiresAt: IMTenantIMTokenExpiryStore.load()
                )
                if !refreshed || nextAccessExpiresAt <= accessExpiresAt {
                    // Transient failures and older successful responses preserve
                    // the durable session. Avoid a hot loop while leaving 401
                    // recovery and the next bounded retry available.
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(
                                IMAuthSessionPreemptiveRefreshPolicy.retryAfterTransientFailureSeconds
                                    * 1_000_000_000
                            )
                        )
                    } catch {
                        return
                    }
                }
            }
        }
    }

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
        print("[JHT Realtime] request url=\(redactedRealtimeURLSummary(request?.url)) fallback=\(redactedRealtimeURLSummary(fallbackURL)) local_fallback=\(Self.isLocalRealtimeFallbackURL(fallbackURL)) quic=\(request?.quicRequest != nil)")
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
            toast = "实时连接地址不可用"
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
        toast = "实时连接中断，正在重连"
    }

    func clearRealtimeReconnectNotice() {
        realtimeReconnectNoticeTask?.cancel()
        realtimeReconnectNoticeTask = nil
        remoteSyncEngine.clearRealtimeReconnectNotice()
        if toast == "实时连接中断，正在重连" {
            toast = nil
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
            print("[JHT Perf] realtime_recovery_refresh reason=\(reason)")
        }
        syncEngine.attachRealtimeRecoveryTask(.refresh, task: task)
    }

    private func shouldSkipRealtimeRecoverySnapshotForRecentPrimarySync(reason: String, now: Date) -> Bool {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedReason == "connect_ack" else {
            return false
        }
        guard let lastRemoteSnapshotPrimarySyncedAt else { return false }
        let age = now.timeIntervalSince(lastRemoteSnapshotPrimarySyncedAt)
        guard age >= 0,
              age < realtimeRecoveryRecentSnapshotCooldownSeconds else {
            return false
        }
        print("[JHT Perf] realtime_recovery_refresh_skip reason=\(normalizedReason) gate=recent_snapshot age_ms=\(Int(age * 1000))")
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
            if self.remoteSyncEngine.currentRemoteSnapshotRefreshSession() == nil {
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
            print("[JHT Perf] realtime_active_conversation_recovery reason=\(reason)")
        }
    }

    private func scheduleRealtimeRecoveryConversationSync(_ conversationID: String?, reason: String) {
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
        print("[JHT Perf] realtime_recovery_conversations reason=\(reason) count=\(conversationIDs.count)")
    }

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
        for conversation in conversations
            where conversation.kind != .system {
            guard let target = conversationStore.messageSequenceRecoveryTarget(for: conversation) else { continue }
            messageSequenceRecoveryAttempts[conversation.id] = 0
            scheduleMessageSequenceRecovery(
                conversationID: conversation.id,
                target: target,
                reason: reason
            )
        }
    }

    func clearCompletedMessageSequenceRecovery(
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
        let scope = remoteDataScopeKey(for: apiContext)
        messageSequenceRecoveryRetryTasks[conversationID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delays[nextAttempt - 1])
            guard let self else { return }
            self.messageSequenceRecoveryRetryTasks[conversationID] = nil
            guard !Task.isCancelled,
                  self.isAuthenticated,
                  self.isCurrentRemoteScope(scope),
                  self.messageSequenceRecoveryTargets[conversationID] != nil else { return }
            self.scheduleRealtimeRecoveryConversationSync(
                conversationID,
                reason: "sequence_retry_\(reason)"
            )
        }
    }

    private func syncMessageSequenceRecovery(
        conversationID: String,
        target: ConversationStore.MessageSequenceRecoveryTarget,
        reason: String
    ) {
        guard apiContext.hasIMSession,
              let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(scope) else { return }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        let historyKey = conversationHistoryStateKey(for: conversation)
        guard conversationStore.beginMessageSync(
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
        Task {
            defer {
                conversationStore.finishMessageSync(
                    historyKey: historyKey,
                    conversationID: conversationID,
                    showLoadingIndicator: false
                )
            }
            var cursor = target.afterSeq
            let startingCursor = cursor
            do {
                for _ in 0..<5 where cursor < target.throughSeq {
                    let page = try await api.syncMessages(
                        context: context,
                        channelID: channelID,
                        channelType: channelType,
                        afterSeq: cursor,
                        limit: 100
                    )
                    guard isCurrentRemoteScope(scope),
                          isCurrentGroupHistoryBoundaryResponse(
                              context: context,
                              channelID: channelID,
                              channelType: channelType,
                              generation: boundaryGeneration
                          ) else { return }
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
                    applyRemoteMessages(
                        page.items,
                        channelID: channelID,
                        channelType: channelType,
                        historyBoundary: syncBoundary,
                        sequenceCoverageAfterSeq: cursor,
                        scheduleSequenceRecovery: false
                    )
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
                guard isCurrentRemoteScope(scope),
                      let updated = conversations.first(where: { $0.id == conversationID }) else { return }
                let coveredThrough = conversationStore.messageSequenceCoveredThrough(in: updated)
                if coveredThrough >= target.throughSeq {
                    clearCompletedMessageSequenceRecovery(
                        conversationID: conversationID,
                        coveredThroughSeq: coveredThrough
                    )
                    return
                }
                if let pending = messageSequenceRecoveryTargets[conversationID] {
                    messageSequenceRecoveryTargets[conversationID] = ConversationStore.MessageSequenceRecoveryTarget(
                        afterSeq: max(pending.afterSeq, coveredThrough),
                        throughSeq: max(pending.throughSeq, target.throughSeq)
                    )
                }
                scheduleMessageSequenceRecoveryRetry(
                    conversationID: conversationID,
                    reason: reason,
                    madeProgress: coveredThrough > startingCursor
                )
            } catch {
                guard isCurrentRemoteScope(scope) else { return }
                logSyncEndpointFailure("/api/im/sync", error: error)
                scheduleMessageSequenceRecoveryRetry(
                    conversationID: conversationID,
                    reason: reason,
                    madeProgress: cursor > startingCursor
                )
            }
        }
    }

    func sendRealtimeSubscribe(for conversation: Conversation) {
        guard isRealtimeConnected else { return }
        let channelID = remoteChannelID(for: conversation)
        let channelType = apiChannelType(for: conversation.kind)
        realtimeClient.subscribe(
            channelID: channelID,
            channelType: channelType,
            tenantID: apiContext.tenantID ?? "",
            imUID: apiContext.imUID ?? "",
            deviceID: apiContext.deviceID
        )
    }

    func resubscribeRealtimeChannels() {
        for conversation in conversations {
            sendRealtimeSubscribe(for: conversation)
        }
        if let activeRealtimeConversationID,
           let active = conversations.first(where: { $0.id == activeRealtimeConversationID }) {
            sendRealtimeSubscribe(for: active)
        }
    }

    private func enqueueRealtimeMessage(_ remote: RemoteMessage) -> RealtimeConnectionDiagnostic.Handling {
        guard isAuthenticated, apiContext.hasIMSession else { return .appAuthRejected }
        let scope = remoteDataScopeKey(for: apiContext)
        guard isCurrentRemoteScope(scope) else { return .appScopeRejected }
        realtimeIngestBuffer.append(remote, scopeKey: scope)
        if realtimeIngestBuffer.count >= realtimeIngestFlushLimit {
            flushPendingRealtimeMessages(reason: "limit")
        } else {
            scheduleRealtimeIngestFlushIfNeeded(scope: scope)
        }
        return .messageQueued
    }

    private func scheduleRealtimeIngestFlushIfNeeded(scope: String) {
        guard realtimeIngestFlushTask == nil else { return }
        realtimeIngestFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: realtimeIngestFlushDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.realtimeIngestFlushTask = nil
            guard self.isCurrentRemoteScope(scope) else {
                self.clearPendingRealtimeMessages(reason: "scope_changed_before_flush")
                return
            }
            self.flushPendingRealtimeMessages(reason: "timer")
        }
    }

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
        let groups = realtimeIngestBuffer.drainGrouped(currentScopeKey: scope)
        guard !groups.isEmpty else { return }
        isFlushingRealtimeIngest = true
        defer { isFlushingRealtimeIngest = false }
        for group in groups {
            applyRemoteMessages(
                group.messages,
                channelID: group.channelID,
                channelType: group.channelType,
                fromRealtime: true
            )
        }
    }

    func clearPendingRealtimeMessages(reason _: String) {
        realtimeIngestFlushTask?.cancel()
        realtimeIngestFlushTask = nil
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

    @discardableResult
    private func handleCertificationRealtimeInvalidation(
        _ envelope: RealtimeEnvelope
    ) -> Bool {
        let supportedEvents: Set<String> = [
            "certification.assignment.updated",
            "certification.label.updated"
        ]
        let outerType = envelope.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let event = payloadString(
            envelope.payload,
            ["event"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eventType = payloadString(
            envelope.payload,
            ["event_type"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCandidate = [outerType, event, eventType].contains {
            $0.hasPrefix("certification.")
        }
        guard isCandidate else { return false }

        guard isAuthenticated,
              apiContext.hasIMSession,
              let activeScope = certificationPresentationRootScope(
                for: apiContext
              ) else {
            purgeCertificationIdentityRoot(rebindCurrentScope: false)
            return true
        }
        if certificationIdentityRoot.scope != activeScope {
            _ = certificationIdentityRoot.bind(activeScope)
            certificationProfileRequestFence.bind(activeScope)
            certificationPresentationRevision &+= 1
            certificationPresentationScopeRevision &+= 1
        } else if certificationProfileRequestFence.scope != activeScope {
            certificationProfileRequestFence.bind(activeScope)
        }

        let tenantID = payloadString(
            envelope.payload,
            ["tenant_id"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tenantID.isEmpty, tenantID != activeScope.tenantID {
            return true
        }
        let subjectUID = payloadString(
            envelope.payload,
            ["subject_id"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectType = payloadString(
            envelope.payload,
            ["subject_type"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let generationFamily = payloadString(
            envelope.payload,
            ["generation_family"]
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eventID = payloadString(
            envelope.payload,
            ["event_id"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let occurredAt = payloadString(
            envelope.payload,
            ["occurred_at"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = payloadInt64(
            envelope.payload,
            ["generation"]
        ) ?? 0
        let revision = payloadInt64(
            envelope.payload,
            ["revision"]
        ) ?? 0
        let hasChangedList: Bool
        if case .array? = envelope.payload["changed"] {
            hasChangedList = true
        } else {
            hasChangedList = false
        }
        let validEvent = supportedEvents.contains(event)
            && eventType == event
            && (outerType == "notification"
                || supportedEvents.contains(outerType))
            && tenantID == activeScope.tenantID
            && subjectType == "user"
            && !subjectUID.isEmpty
            && generationFamily == "certification"
            && generation > 0
            && revision > 0
            && !eventID.isEmpty
            && !occurredAt.isEmpty
            && hasChangedList

        guard validEvent else {
            let affectedUIDs = subjectUID.isEmpty
                ? certificationIdentityRoot.exactUIDs
                : [subjectUID]
            certificationProfileRequestFence.invalidate(affectedUIDs)
            if !affectedUIDs.isEmpty {
                _ = certificationIdentityRoot.markMalformedForRefetch(
                    exactUIDs: affectedUIDs
                )
                ensureCertificationPresentations(
                    forExactUIDs: affectedUIDs
                )
            }
            return true
        }

        certificationProfileRequestFence.invalidate([subjectUID])
        let outcome = certificationIdentityRoot.invalidate(
            exactUID: subjectUID,
            tenantID: tenantID,
            generation: generation,
            revision: revision
        )
        if certificationPresentationOutcomeChangesUI(outcome) {
            certificationPresentationRevision &+= 1
        }
        if outcome == .invalidated || outcome == .purgedForRefetch {
            ensureCertificationPresentations(forExactUIDs: [subjectUID])
        }
        return true
    }

    func handleRealtimeEnvelope(_ envelope: RealtimeEnvelope) {
        // Retain the originating observation across synchronous disconnect/scope changes.
        // It never changes this handler's existing admission or business branches.
        let diagnostic = (realtimeClient as? RealtimeClient)?.currentEnvelopeDiagnostic
        var diagnosticHandling: RealtimeConnectionDiagnostic.Handling = .appCallbackReturned
        defer { diagnostic?.event.handling = diagnosticHandling }
        if DeviceRevocationDetector.matches(envelope: envelope) {
            clearPendingRealtimeMessages(reason: "device_revoked")
            disconnectRealtime(shouldReconnect: false)
            logSyncEndpointFailure("/im/ws", error: IMAPIError.unauthorized(DeviceRevocationDetector.logoutMessage))
            handleCurrentDeviceRevoked()
            diagnostic?.event.handlingCode = .deviceRevoked
            diagnosticHandling = .deviceRevoked
            return
        }
        let activeTenantID = apiContext.tenantID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let activeViewerID = apiContext.imUID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        handleAvatarRealtimeOutcome(
            avatarRealtimeProjection.consume(
                envelope,
                activeTenantID: activeTenantID
            )
        )
        handlePresenceConnectivityOutcome(
            presenceConnectivityProjection.consume(
                envelope,
                activeTenantID: activeTenantID,
                activeViewerID: activeViewerID
            )
        )
        switch envelope.type {
        case "connect_ack":
            schedulePersistedMessageSequenceRecoveries(reason: "realtime_connect")
            scheduleDeliveryAcksForPersistedMessages()
            if let ticket = localMessageTicket {
                scheduleDurableReadAckRecovery(ticket: ticket, runImmediately: true)
            }
            for conversation in conversations where conversation.kind != .system {
                syncReadReceiptsIfNeeded(conversation.id)
            }
        case "pong", "subscribe_ack":
            break
        case "message", "message_push":
            if let remote = decodeRealtimeMessage(envelope) {
                diagnosticHandling = enqueueRealtimeMessage(remote)
            } else {
                flushPendingRealtimeMessagesIfNeeded(reason: "message_decode_fallback")
                refreshRealtimeFallback(envelope)
                diagnosticHandling = .fallbackScheduled
            }
        case "send_ack":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_send_ack")
            if let remote = decodeRealtimeMessage(envelope) {
                applyRemoteMessages([remote], channelID: remote.channelID, channelType: remote.channelType, fromRealtime: true)
            } else {
                refreshRealtimeFallback(envelope)
            }
        case "message_extra":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_message_extra")
            handleRealtimeMessageExtra(envelope)
        case "message_receipt":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_message_receipt")
            if let receipt = decodeRealtimePayload(RemoteMessageReceipt.self, key: "receipt", envelope: envelope)
                ?? decodeRealtimeEnvelopePayload(RemoteMessageReceipt.self, envelope: envelope) {
                applyRealtimeMessageReceipt(receipt)
            } else {
                refreshRealtimeFallback(envelope)
            }
        case "conversation_read":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_conversation_read")
            handleConversationReadWatermark(envelope)
        case "conversation_update":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_conversation_update")
            scheduleRealtimeRecoveryRefresh(reason: "conversation_update")
        case "resync":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_resync")
            handleRealtimeResync(envelope)
        case "group_left", "group_dissolved", "group_member_left":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_lifecycle")
            let groupID = realtimeGroupID(from: envelope)
            applyGroupLifecycleEvent(event: envelope.type, groupID: groupID)
        case "group_announcement.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_announcement")
            refreshGroupAnnouncementFromRealtime(envelope)
        case "group.member.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_member_profile")
            handleGroupMemberProfileRealtime(envelope)
        case "group.settings.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_settings")
            handleGroupSettingsUpdatedRealtime(envelope)
        case "group.owner.transferred":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_group_owner_transfer")
            handleGroupOwnerTransferredRealtime(envelope)
        case "tenant.policy.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_tenant_policy_update")
            refreshGroupMemberCountPolicyAfterRealtimeInvalidation(envelope: envelope)
        case "certification.assignment.updated",
             "certification.label.updated":
            flushPendingRealtimeMessagesIfNeeded(
                reason: "before_certification_invalidation"
            )
            handleCertificationRealtimeInvalidation(envelope)
        case "friend_application.created",
             "friend_application.reviewed",
             "friend_application.rejected",
             "friend_application.approved",
             "friend_application.updated",
             "friend_application.suppressed",
             "friend_application.cancelled",
             "friend_relation.established":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_friend_relation")
            Task {
                await refreshFriendApplicationsFromRealtime(
                    event: envelope.type,
                    envelope: envelope
                )
            }
        case "profile_updated",
             "profile.updated",
             "blacklist.updated",
             "blacklist.added",
             "blacklist.removed",
             "friend_remark.updated",
             "contact.remark.updated":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_profile_contact_invalidation")
            scheduleProfileContactRealtimeReconcile(event: envelope.type)
        case "rtc.call.ringing", "rtc.call.accepted", "rtc.call.rejected", "rtc.call.canceled", "rtc.call.ended", "rtc.call.timed_out", "rtc.call.busy", "rtc_call":
            flushPendingRealtimeMessagesIfNeeded(reason: "before_rtc_event")
            handleRTCCallEvent(envelope)
        case "notification":
            if envelope.isRTCCallNotification {
                ensureRTCSignalingRefreshActive(reason: "realtime_rtc_notification")
            }
            flushPendingRealtimeMessagesIfNeeded(reason: "before_notification")
            _ = handleCertificationRealtimeInvalidation(envelope)
            let event = friendRealtimePayloadString(
                envelope,
                keys: ["event", "event_type", "notification_type", "notice_type"]
            ).lowercased()
            let kind = friendRealtimePayloadString(
                envelope,
                keys: ["kind", "notification_kind"]
            ).lowercased()
            let senderUID = (envelope.payload["sender_uid"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if event == "group_announcement.updated" || kind == "group_announcement" {
                refreshGroupAnnouncementFromRealtime(envelope)
            }
            if event == "group.member.updated" {
                handleGroupMemberProfileRealtime(envelope)
            }
            if event == "group.settings.updated" || event == "group_settings_updated" {
                handleGroupSettingsUpdatedRealtime(envelope)
            }
            if event == "group.owner.transferred" || event == "group_owner_transferred" {
                handleGroupOwnerTransferredRealtime(envelope)
            }
            if event == "tenant.policy.updated" || event == "tenant_policy_updated" {
                refreshGroupMemberCountPolicyAfterRealtimeInvalidation(envelope: envelope)
            }
            if event == "group_left" || event == "group_dissolved" || event == "group_member_left" {
                applyGroupLifecycleEvent(event: event, groupID: realtimeGroupID(from: envelope))
            }
            if Self.isFriendRelationRealtimeEvent(event: event, kind: kind) {
                Task { await refreshFriendApplicationsFromRealtime(event: event, envelope: envelope) }
            }
            if [
                "profile_updated",
                "profile.updated",
                "blacklist.updated",
                "blacklist.added",
                "blacklist.removed",
                "friend_remark.updated",
                "contact.remark.updated"
            ].contains(event) {
                scheduleProfileContactRealtimeReconcile(event: event)
            }
            if event == "inbox.updated"
                || kind == "friend_sensitive_notice"
                || senderUID == "system_notification"
                || senderUID == "system_message" {
                Task { await refreshInboxSilently() }
            }
        case "error":
            #if DEBUG
            if authPolicyScreenshotModeEnabled {
                diagnosticHandling = .screenshotIgnored
                return
            }
            #endif
            let code = realtimeErrorString(from: envelope, keys: ["code", "reason_code", "reasonCode"])
            let message = realtimeErrorString(from: envelope, keys: ["message", "reason", "reason_text"])
            diagnostic?.event.serverCode = .init(code: code)
            diagnosticHandling = .errorUnhandled
            if isNotFriendsForbiddenMessage("\(code) \(message)") {
                handleRealtimeNotFriendsError(envelope)
                diagnostic?.event.handlingCode = .notFriends
                diagnosticHandling = .notFriendsHandled
                return
            }
            if code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "security_blocked" {
                let info = securityBlockedInfo(from: envelope)
                handleSecurityBlocked(info)
                logSyncEndpointFailure("/im/ws", error: IMAPIError.securityBlocked(info))
                diagnostic?.event.handlingCode = .securityBlocked
                diagnosticHandling = .securityBlockedHandled
                return
            }
            if let quotaCode = IMAPIClient.licenseQuotaErrorCode(code) {
                disconnectRealtime(shouldReconnect: false)
                toast = IMAPIClient.licenseQuotaUserMessage(for: quotaCode)
                logSyncEndpointFailure(
                    "/im/ws",
                    error: IMAPIError.businessForbidden(
                        code: quotaCode,
                        message: IMAPIClient.licenseQuotaUserMessage(for: quotaCode),
                        error: nil
                    )
                )
                diagnostic?.event.handlingCode = .init(code: quotaCode)
                diagnosticHandling = .quotaDisconnected
                return
            }
            if let accessCode = workspaceAccessCode(from: "\(code) \(message)") {
                let affectsCurrent = markWorkspaceAccessBlocked(accessCode)
                disconnectRealtime(shouldReconnect: false)
                if affectsCurrent {
                    syncFailureMessage = workspaceAccessMessage(for: accessCode)
                    forceWorkspaceSelectionForCurrentAccessBlock(accessCode)
                }
                toast = workspaceAccessMessage(for: accessCode)
                logSyncEndpointFailure("/im/ws", error: IMAPIError.forbidden(accessCode))
                diagnostic?.event.handlingCode = .init(code: accessCode)
                diagnosticHandling = affectsCurrent ? .workspaceSelectionForced : .workspaceDisconnected
                return
            }
            if code == "connect_failed" || code == "unauthorized" || code == "forbidden" || code == "connect_required" {
                disconnectRealtime(shouldReconnect: false)
                toast = "实时连接暂不可用，聊天数据会继续同步"
                logSyncEndpointFailure("/im/ws", error: IMAPIError.server("websocket_\(code)"))
                diagnostic?.event.handlingCode = .init(code: code)
                diagnosticHandling = .authDisconnected
            }
        default:
            if envelope.type
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("certification.") {
                flushPendingRealtimeMessagesIfNeeded(
                    reason: "before_malformed_certification_invalidation"
                )
                _ = handleCertificationRealtimeInvalidation(envelope)
            }
        }
    }

    private func scheduleProfileContactRealtimeReconcile(event: String) {
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        profileContactRealtimeRefreshTask?.cancel()
        profileContactRealtimeRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            if normalizedEvent == "profile_updated" || normalizedEvent == "profile.updated" {
                let authorityRequest = self.beginCurrentProfileRead(context: context)
                if let profile = try? await self.api.meProfile(context: context),
                   self.isCurrentRemoteScope(scope) {
                    _ = self.applyMeProfile(profile, authorityRequest: authorityRequest)
                }
            }
            guard !Task.isCancelled, self.isCurrentRemoteScope(scope) else { return }
            await self.refreshFriendApplicationsAndRelations(context: context, scope: scope)
            if self.isCurrentRemoteScope(scope) {
                self.profileContactRealtimeRefreshTask = nil
            }
        }
    }

    private func handleRealtimeResync(_ envelope: RealtimeEnvelope) {
        let requiresFullSync = envelope.payload["full_sync"]?.boolValue
            ?? envelope.payload["fullSync"]?.boolValue
            ?? envelope.payload["reset"]?.boolValue
            ?? false
        if requiresFullSync {
            scheduleRealtimeRecoveryRefresh(reason: "realtime_resync_full")
            return
        }
        guard case .array(let values)? = envelope.payload["channels"], !values.isEmpty else {
            refreshRealtimeFallback(envelope)
            return
        }
        var scheduledAny = false
        var hasUnknownChannel = false
        for value in values {
            let channelID: String
            let channelType: String
            switch value {
            case .object(let object):
                channelID = payloadString(object, ["channel_id", "channelID", "conversation_id", "conversationID", "id"])
                channelType = payloadString(object, ["channel_type", "channelType", "type"])
            case .string(let id):
                channelID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                channelType = ""
            default:
                hasUnknownChannel = true
                continue
            }
            let normalizedID = normalizedRemoteChannelID(channelID, channelType: channelType)
            guard !normalizedID.isEmpty else {
                hasUnknownChannel = true
                continue
            }
            if let conversation = conversations.first(where: { $0.id == normalizedID || remoteChannelID(for: $0) == normalizedID }) {
                scheduleRealtimeRecoveryConversationSync(conversation.id, reason: "realtime_resync_channel")
                scheduledAny = true
            } else {
                hasUnknownChannel = true
            }
        }
        if hasUnknownChannel || !scheduledAny {
            scheduleRealtimeRecoveryRefresh(reason: hasUnknownChannel ? "realtime_resync_unknown_channel" : "realtime_resync_empty")
        }
    }

    func normalizedReadWatermarkChannelType(channelID: String, channelType: String) -> String {
        apiChannelType(for: conversationKind(from: channelType, channelID: channelID))
    }

    func currentReadWatermarkScope(
        channelID rawChannelID: String,
        channelType rawChannelType: String,
        context: IMAPIContext? = nil
    ) -> ConversationStore.ReadWatermarkScope? {
        let resolvedContext = context ?? apiContext
        let normalizedChannelID = normalizedRemoteChannelID(rawChannelID, channelType: rawChannelType)
        let normalizedChannelType = normalizedReadWatermarkChannelType(
            channelID: normalizedChannelID,
            channelType: rawChannelType
        )
        return ConversationStore.ReadWatermarkScope(
            tenantID: resolvedContext.tenantID ?? "",
            imUID: resolvedContext.imUID ?? "",
            appID: resolvedContext.appID,
            channelID: normalizedChannelID,
            channelType: normalizedChannelType
        )
    }

    private func readWatermark(
        from remote: RemoteConversationReadWatermark,
        context: IMAPIContext
    ) -> ConversationStore.ReadWatermark? {
        let activeTenantID = (context.tenantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let activeIMUID = (context.imUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let activeAppID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTenantID = remote.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteIMUID = remote.imUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteAppID = remote.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventID = remote.eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteChannelType = remote.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !activeTenantID.isEmpty,
              !activeIMUID.isEmpty,
              !activeAppID.isEmpty,
              !eventID.isEmpty,
              ["direct", "group", "system"].contains(remoteChannelType),
              remoteTenantID == activeTenantID,
              remoteIMUID == activeIMUID,
              remoteAppID == activeAppID else {
            return nil
        }
        let normalizedChannelID = normalizedRemoteChannelID(remote.channelID, channelType: remote.channelType)
        let normalizedChannelType = normalizedReadWatermarkChannelType(
            channelID: normalizedChannelID,
            channelType: remote.channelType
        )
        return ConversationStore.ReadWatermark(
            eventID: eventID,
            tenantID: remoteTenantID,
            imUID: remoteIMUID,
            appID: remoteAppID,
            channelID: normalizedChannelID,
            channelType: normalizedChannelType,
            lastReadSeq: remote.lastReadSeq,
            occurredAt: remote.occurredAt
        )
    }

    func cancelLocalNotifications(for scope: ConversationStore.ReadWatermarkScope, throughSeq: Int64) {
        guard let watermark = IOSNotificationReadWatermark(
            tenantID: scope.tenantID,
            imUID: scope.imUID,
            appID: scope.appID,
            channelID: scope.channelID,
            channelType: scope.channelType,
            lastReadSeq: throughSeq
        ) else {
            return
        }
        IOSNotificationRuntime.shared.cancelLocalNotifications(matching: watermark)
    }

    private func handleConversationReadWatermark(_ envelope: RealtimeEnvelope) {
        let context = apiContext
        guard context.hasIMSession else { return }
        guard let remote = decodeRealtimePayload(RemoteConversationReadWatermark.self, key: "read_watermark", envelope: envelope)
                ?? decodeRealtimeEnvelopePayload(RemoteConversationReadWatermark.self, envelope: envelope),
              let watermark = readWatermark(from: remote, context: context) else {
            return
        }
        let effectiveReadSeq = conversationStore.rememberReadWatermark(watermark)
        cancelLocalNotifications(for: watermark.scope, throughSeq: effectiveReadSeq)
        if let conversation = conversations.first(where: { conversation in
            conversation.id == watermark.scope.channelID
                || normalizedRemoteChannelID(
                    remoteChannelID(for: conversation),
                    channelType: watermark.scope.channelType
                ) == watermark.scope.channelID
        }) {
            conversationStore.advanceRead(conversationID: conversation.id, through: effectiveReadSeq)
            scheduleRemoteSnapshotCacheWrite(scope: remoteDataScopeKey(for: context), source: .realtime)
        }
        scheduleRealtimeRecoveryRefresh(reason: "conversation_read")
    }

    private func refreshRealtimeFallback(_ envelope: RealtimeEnvelope) {
        flushPendingRealtimeMessagesIfNeeded(reason: "before_realtime_fallback")
        let channelID = envelope.payload["channel_id"]?.stringValue ?? ""
        let channelType = envelope.payload["channel_type"]?.stringValue ?? ""
        if !channelID.isEmpty, !channelType.isEmpty {
            if let conversation = conversations.first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) {
                scheduleRealtimeRecoveryConversationSync(conversation.id, reason: "realtime_fallback_channel")
            } else {
                scheduleRealtimeRecoveryRefresh(reason: "realtime_fallback_unknown_channel")
            }
            return
        }
        scheduleRealtimeRecoveryRefresh(reason: "realtime_fallback")
    }

    private func realtimeGroupID(from envelope: RealtimeEnvelope) -> String {
        let keys = ["group_id", "groupId", "channel_id", "channelID", "id"]
        for key in keys {
            if let value = envelope.payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let payload = envelope.payload["payload"]?.objectValue {
            for key in keys {
                if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return ""
    }

    private func handleGroupSettingsUpdatedRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = realtimeGroupID(from: envelope)
        guard !groupID.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "group_settings_missing_group")
            return
        }
        func refreshAuthoritativeState() {
            Task {
                await refreshGroupBundle(
                    groupID: groupID,
                    silent: true,
                    includeSecondaryData: false,
                    queueAfterInFlight: true
                )
            }
        }
        let payload = envelope.payload["payload"]?.objectValue ?? envelope.payload
        let changedValue = payload["changed"] ?? envelope.payload["changed"]
        var changedFields: [String] = []
        if case .array(let values)? = changedValue {
            changedFields = values.compactMap(\.stringValue).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        guard let settingsValue = payload["settings"] ?? envelope.payload["settings"],
              let data = try? JSONSerialization.data(withJSONObject: settingsValue.anyValue),
              let settings = try? realtimeDecoder.decode(RemoteGroupSettings.self, from: data) else {
            refreshAuthoritativeState()
            return
        }

        let context = apiContext
        let scopeKey = groupMuteScopeKey(groupID: groupID, context: context)
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            refreshAuthoritativeState()
            return
        }
        let incomingGroupRevision = max(
            settings.groupRevision,
            (payload["group_revision"] ?? envelope.payload["group_revision"])?
                .stringValue
                .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        )
        let currentGroupRevision = groups[index].groupRevision
        if incomingGroupRevision > 0 {
            guard incomingGroupRevision > currentGroupRevision else { return }
            if changedFields.contains("name") || changedFields.contains("avatar") {
                refreshAuthoritativeState()
                return
            }
            groups[index].groupRevision = incomingGroupRevision
            groups[index].groupDescription = settings.groupDescription ?? groups[index].groupDescription
            groups[index].inviteConfirmRequired = settings.inviteConfirmRequired
            groups[index].historyVisible = settings.historyVisible
            let carriesMuteMutation = changedFields.contains { field in
                field == "all_muted" || field == "all_muted_mode"
                    || field == "all_muted_start_at" || field == "all_muted_end_at"
                    || field == "all_muted_active" || field == "all_muted_updated_at"
            }
            if !carriesMuteMutation { return }
        } else if currentGroupRevision > 0 {
            refreshAuthoritativeState()
            return
        } else if changedFields.contains("description") {
            refreshAuthoritativeState()
        }
        let generationValue = ["generation", "revision"]
            .compactMap { payload[$0] ?? envelope.payload[$0] }
            .first
        let generation = generationValue?.stringValue.flatMap {
            Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if generationValue != nil, generation == nil || (generation ?? 0) <= 0 {
            refreshAuthoritativeState()
            return
        }
        let currentGeneration = groupMuteRealtimeGenerationByScope[scopeKey] ?? 0
        let generationIsFresh = generation.map { $0 > currentGeneration }

        let incomingUpdatedAtRaw = settings.allMutedUpdatedAt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentUpdatedAtRaw = groups[index].allMuteUpdatedAt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingUpdatedAt = incomingUpdatedAtRaw.isEmpty ? nil : parseRemoteDate(incomingUpdatedAtRaw)
        let currentUpdatedAt = currentUpdatedAtRaw.isEmpty ? nil : parseRemoteDate(currentUpdatedAtRaw)
        if (!incomingUpdatedAtRaw.isEmpty && incomingUpdatedAt == nil)
            || (!currentUpdatedAtRaw.isEmpty && currentUpdatedAt == nil) {
            refreshAuthoritativeState()
            return
        }
        let updatedAtIsFresh: Bool? = incomingUpdatedAt.map { incoming in
            guard let currentUpdatedAt else { return true }
            return incoming > currentUpdatedAt
        }
        if let generationIsFresh,
           let updatedAtIsFresh,
           generationIsFresh != updatedAtIsFresh {
            refreshAuthoritativeState()
            return
        }
        if generationIsFresh == false || updatedAtIsFresh == false {
            return
        }
        guard generationIsFresh == true || updatedAtIsFresh == true else {
            refreshAuthoritativeState()
            return
        }
        if let generation {
            groupMuteRealtimeGenerationByScope[scopeKey] = generation
        }

        groupMuteMutationTokensByScope[scopeKey] = nil
        groupMuteMutatingIDs.remove(groupID)
        groupMuteErrorMessages[groupID] = nil
        let projection = resolvedGroupMuteFields(
            allMuted: settings.allMuted,
            modeRawValue: settings.allMutedMode,
            active: settings.allMutedActive,
            startAtRawValue: settings.allMutedStartAt,
            endAtRawValue: settings.allMutedEndAt,
            serverTimeRawValue: settings.serverTime,
            nextBoundaryRawValue: settings.nextBoundaryAt,
            updatedAt: settings.allMutedUpdatedAt,
            repairRequired: settings.allMutedRepairRequired
        )
        groups[index].allMuted = projection.allMuted
        groups[index].allMuteMode = projection.mode
        groups[index].allMuteActive = projection.active
        groups[index].allMuteStart = projection.startAt
        groups[index].allMuteEnd = projection.endAt
        groups[index].allMuteServerTime = projection.serverTime
        groups[index].allMuteNextBoundary = projection.nextBoundaryAt
        groups[index].allMuteRepairRequired = projection.repairRequired
        groups[index].allMuteUpdatedAt = projection.updatedAt.isEmpty
            ? currentUpdatedAtRaw
            : projection.updatedAt
        scheduleGroupMuteBoundaryRefresh(for: groups[index], context: context)
    }

    private func handleGroupOwnerTransferredRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = realtimeGroupID(from: envelope)
        guard !groupID.isEmpty else {
            clearGroupAnnouncementReadCounts()
            scheduleRealtimeRecoveryRefresh(reason: "group_owner_transfer_missing_group")
            return
        }
        clearGroupAnnouncementReadCounts(groupID: groupID)
        Task {
            await refreshGroupBundle(
                groupID: groupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            await refreshGroupAnnouncements(groupID: groupID, silent: true)
        }
    }

    private func refreshFriendApplicationsFromRealtime(event: String, envelope: RealtimeEnvelope) async {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        guard isAuthenticated,
              context.hasIMSession,
              isCurrentRemoteScope(scope) else { return }
        let beforePendingCount = pendingFriendRequestCount
        await refreshFriendApplicationsAndRelations(context: context, scope: scope)
        guard isCurrentRemoteScope(scope) else { return }
        if shouldShowIncomingFriendApplicationToast(
            event: event,
            envelope: envelope,
            beforePendingCount: beforePendingCount
        ) {
            toast = "收到新的好友申请"
        }
        await refreshInboxSilently()
    }

    private func shouldShowIncomingFriendApplicationToast(event: String, envelope: RealtimeEnvelope, beforePendingCount: Int) -> Bool {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEvent == "friend_application.created"
                || normalizedEvent == "friend_application.approved"
                || normalizedEvent == "friend.request.created"
                || normalizedEvent == "friend_request.created" else { return false }
        let status = friendRealtimePayloadString(envelope, keys: ["status", "application_status"])
        let outcome = friendRealtimePayloadString(envelope, keys: ["outcome"])
        guard !Self.isSuppressedFriendApplication(status: status, outcome: outcome) else {
            return false
        }
        let targetUID = (envelope.payload["target_uid"]?.stringValue
            ?? envelope.payload["targetUid"]?.stringValue
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !targetUID.isEmpty {
            guard isCurrentRealtimeIdentity(targetUID) else { return false }
        }
        let applicantUID = (envelope.payload["applicant_uid"]?.stringValue
            ?? envelope.payload["applicantUid"]?.stringValue
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicantUID.isEmpty, isCurrentRealtimeIdentity(applicantUID) {
            return false
        }
        return pendingFriendRequestCount > beforePendingCount
    }

    private func friendRealtimePayloadString(_ envelope: RealtimeEnvelope, keys: [String]) -> String {
        for key in keys {
            if let value = envelope.payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let nested = envelope.payload["payload"]?.objectValue {
            for key in keys {
                if let value = nested[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return ""
    }

    private func isCurrentRealtimeIdentity(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let candidates = [
            apiContext.imUID,
            apiContext.accountID,
            currentUser.id,
            currentUser.userID,
            currentUser.username,
            currentUser.email,
        ]
        return candidates.contains { candidate in
            candidate?.trimmingCharacters(in: .whitespacesAndNewlines) == token
        }
    }

    private func refreshGroupAnnouncementFromRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = envelope.payload["group_id"]?.stringValue
            ?? envelope.payload["groupID"]?.stringValue
            ?? envelope.payload["channel_id"]?.stringValue
            ?? envelope.payload["channelId"]?.stringValue
            ?? ""
        let trimmedGroupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGroupID.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "group_announcement_missing_group")
            return
        }
        Task { await refreshGroupAnnouncements(groupID: trimmedGroupID, silent: true) }
    }

    private func handleGroupMemberProfileRealtime(_ envelope: RealtimeEnvelope) {
        let groupID = realtimeGroupID(from: envelope)
        guard !groupID.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "group_member_profile_missing_group")
            return
        }
        let nestedPayload = envelope.payload["payload"]?.objectValue ?? [:]
        let changedValue = envelope.payload["changed"] ?? nestedPayload["changed"]
        if case .array(let changed)? = changedValue {
            let fields = changed.compactMap(\.stringValue).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard fields.contains("group_nickname") else { return }
        }
        let generation = payloadInt64(
            envelope.payload,
            ["group_membership_generation", "generation", "revision"]
        ) ?? payloadInt64(
            nestedPayload,
            ["group_membership_generation", "generation", "revision"]
        ) ?? 0
        let key = groupMemberProfileCacheKey(groupID: groupID)
        let highestKnownGeneration = max(
            groupMemberProfileGenerationByScopedGroupKey[key] ?? 0,
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] ?? 0
        )
        if generation > 0, generation <= highestKnownGeneration {
            return
        }
        if generation > 0 {
            minimumGroupMemberProfileGenerationByScopedGroupKey[key] = generation
        }
        groupMemberProfileRefreshTasks[key]?.cancel()
        let scope = remoteDataScopeKey(for: apiContext)
        groupMemberProfileRefreshTasks[key] = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            await self.refreshGroupBundle(
                groupID: groupID,
                silent: true,
                includeSecondaryData: true,
                queueAfterInFlight: true
            )
            guard !Task.isCancelled,
                  self.isCurrentRemoteScope(scope) else { return }
            self.groupMemberProfileRefreshTasks[key] = nil
        }
    }

    private func decodeRealtimeMessage(_ envelope: RealtimeEnvelope) -> RemoteMessage? {
        if let message = decodeRealtimePayload(RemoteMessage.self, key: "message", envelope: envelope) {
            return message
        }
        // Match the RTC forms recognized by transport continuity, without
        // treating an invalid nested message as a different outer message.
        guard envelope.payload["message"] == nil,
              let message = decodeRealtimeEnvelopePayload(RemoteMessage.self, envelope: envelope),
              message.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rtc_call_record" else {
            return nil
        }
        return message
    }

    private func decodeRealtimePayload<T: Decodable>(_ type: T.Type, key: String, envelope: RealtimeEnvelope) -> T? {
        guard let value = envelope.payload[key],
              let data = try? JSONSerialization.data(withJSONObject: value.anyValue) else { return nil }
        return try? realtimeDecoder.decode(T.self, from: data)
    }

    private func handleRealtimeMessageExtra(_ envelope: RealtimeEnvelope) {
        guard let extra = decodeRealtimePayload(RemoteMessageExtra.self, key: "extra", envelope: envelope)
                ?? decodeRealtimeEnvelopePayload(RemoteMessageExtra.self, envelope: envelope) else {
            scheduleRealtimeRecoveryRefresh(reason: "message_extra_decode_fallback")
            return
        }
        if extra.isReaction || extra.normalizedExtraType == "recall" || extra.normalizedExtraType == "edit" || extra.normalizedExtraType == "pin" || isAdminDeleteExtra(extra) || searchInvalidationEvent(from: extra) != nil {
            applyRemoteMessageExtra(extra, fromRealtime: true)
            return
        }
        scheduleRealtimeRecoveryRefresh(reason: "message_extra_unknown")
        if let activeRealtimeConversationID {
            syncConversationMessagesIfNeeded(activeRealtimeConversationID, force: true)
        }
    }

    @discardableResult
    private func applyRealtimeRecall(_ extra: RemoteMessageExtra) -> Bool {
        if let context = mediaCacheScopeContext {
            invalidateIndexedMediaCache(
                messageID: extra.messageID,
                state: .recalled,
                authorityVersion: String(max(extra.version, 0)),
                context: context
            )
        }
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        if !channelID.isEmpty {
            return conversationStore.applyRecall(
                messageID: extra.messageID,
                conversationID: channelID,
                channelIDForConversation: { conversation in
                    self.remoteChannelID(for: conversation)
                }
            )
        }
        return conversationStore.applyRecall(messageID: extra.messageID)
    }

    func applyRemoteMessageExtra(_ extra: RemoteMessageExtra, fromRealtime: Bool) {
		let extraTenantID = extra.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
		let currentTenantID = (apiContext.tenantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard extraTenantID.isEmpty || (!currentTenantID.isEmpty && extraTenantID == currentTenantID) else { return }
        if let invalidation = searchInvalidationEvent(from: extra) {
            applySearchInvalidation(invalidation)
        }
        if extra.isReaction {
            guard conversationStore.shouldApplyReactionExtra(extra) else {
                conversationStore.applyDedupedReactionExtraIfMissing(
                    extra,
                    currentUserIDs: currentUserIdentitySet(),
                    makeReactionDetail: reactionDetail(from:id:)
                )
                return
            }
            applyMessageReaction(
                messageID: extra.messageID,
                emoji: extra.emoji,
                operatorUID: extra.operatorUID,
                action: extra.action
            )
            let didApply = applyMessageReactionDetail(extra)
            applyReactionReadStateIfNeeded(extra)
            if fromRealtime {
                if !isMessageExtraAtOrBelowEffectiveRead(extra) {
                    markReactionReminderIfNeeded(extra)
                }
                if didApply {
                    scheduleRealtimeRecoveryRefresh(reason: "reaction_extra_applied")
                } else {
                    refreshMessageExtraFallback(extra)
                }
            }
            return
        }
        if extra.normalizedExtraType == "recall" {
            let didApply = applyRealtimeRecall(extra)
            if fromRealtime, !didApply {
                refreshMessageExtraFallback(extra)
            }
            return
        }
        if extra.normalizedExtraType == "edit" {
            let didApply = applyRemoteEditExtra(extra)
			if didApply {
				let scope = contentCacheScopeKey
				if !scope.isEmpty { scheduleRemoteSnapshotCacheWrite(scope: scope) }
			}
            if fromRealtime {
                if didApply {
                    scheduleRealtimeRecoveryRefresh(reason: "edit_extra_applied")
                } else {
                    refreshMessageExtraFallback(extra)
                }
            }
            return
        }
        if isAdminDeleteExtra(extra) {
            if applyAdminDeletedMessage(
                messageID: extra.messageID,
                authorityVersion: String(max(extra.version, 0))
            ) {
                let scope = contentCacheScopeKey
                if !scope.isEmpty {
                    scheduleRemoteSnapshotCacheWrite(scope: scope)
                }
            }
            return
        }
        if extra.normalizedExtraType == "pin" {
            let didApply = applyRemotePinExtra(extra)
            if fromRealtime {
                if didApply {
                    scheduleRealtimeRecoveryRefresh(reason: "pin_extra_applied")
                } else {
                    refreshMessageExtraFallback(extra)
                }
            }
        }
    }

    // JHT_MOD_BEGIN MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改开始：同步分页 extras 批量处理 reaction，减少主线程反复扫描和发布
    func applySyncedRemoteMessageExtras(_ extras: [RemoteMessageExtra]) {
        guard !extras.isEmpty else { return }
        var pendingReactionExtras: [RemoteMessageExtra] = []
        pendingReactionExtras.reserveCapacity(extras.count)

        func flushPendingReactionExtras() {
            guard !pendingReactionExtras.isEmpty else { return }
            #if DEBUG
            let startedAt = CFAbsoluteTimeGetCurrent()
            #endif
            let result = conversationStore.applySyncedReactionExtras(
                pendingReactionExtras,
                currentUserIDs: currentUserIdentitySet(),
                makeReactionDetail: reactionDetail(from:id:)
            )
            #if DEBUG
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            if elapsedMs >= 8 || result.processed > 4 {
                print("[JHT Perf] message_extras_reaction_batch_apply processed=\(result.processed) changed=\(result.changed) conversations=\(result.conversationsChanged) messages=\(result.messagesChanged) skipped=\(result.skipped.count) elapsed_ms=\(elapsedMs)")
            }
            #endif
            pendingReactionExtras.removeAll(keepingCapacity: true)
        }

        for extra in extras {
            let extraTenantID = extra.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTenantID = (apiContext.tenantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard extraTenantID.isEmpty || (!currentTenantID.isEmpty && extraTenantID == currentTenantID) else { continue }
            guard extra.isReaction else {
                flushPendingReactionExtras()
                applyRemoteMessageExtra(extra, fromRealtime: false)
                continue
            }
            if let invalidation = searchInvalidationEvent(from: extra) {
                applySearchInvalidation(invalidation)
            }
            pendingReactionExtras.append(extra)
        }
        flushPendingReactionExtras()
    }
    // JHT_MOD_END MESSAGE_EXTRAS_BATCH_REACTION_APPLY_PERF_20260912 - 修改结束

    private func isAdminDeleteExtra(_ extra: RemoteMessageExtra) -> Bool {
        let type = extra.normalizedExtraType
        let action = extra.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let event = (extra.payload["event"]?.stringValue ?? extra.payload["event_type"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "admin_delete",
            "admin_deleted",
            "admin_delete_message",
            "message_admin_delete",
            "group_admin_delete",
            "group_admin_delete_message",
            "message_deleted",
            "tombstone"
        ].contains(type)
            || ["admin_delete", "admin_deleted", "admin_delete_message", "group_admin_delete_message", "delete_for_all", "deleted", "tombstone"].contains(action)
            || ["admin_delete", "admin_delete_message", "message_admin_delete", "group_admin_delete_message", "message_deleted"].contains(event)
    }

    @discardableResult
    private func applyRemoteEditExtra(_ extra: RemoteMessageExtra) -> Bool {
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        return conversationStore.applyRemoteEditExtra(
            extra,
            normalizedChannelID: channelID,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            }
        )
    }

    @discardableResult
    private func applyRemotePinExtra(_ extra: RemoteMessageExtra) -> Bool {
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        return conversationStore.applyRemotePinExtra(
            extra,
            normalizedChannelID: channelID,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            }
        )
    }

    private func markReactionReminderIfNeeded(_ extra: RemoteMessageExtra) {
        conversationStore.markReactionReminderIfNeeded(
            extra,
            currentUserIDs: currentUserIdentitySet(),
            activeConversationID: activeRealtimeConversationID,
            channelIDForConversation: { conversation in
                remoteChannelID(for: conversation)
            }
        )
    }

    @discardableResult
    func applyMessageReaction(messageID: String, emoji: String, operatorUID: String, action: String) -> Bool {
        conversationStore.applyMessageReaction(
            messageID: messageID,
            emoji: emoji,
            operatorUID: operatorUID,
            action: action,
            currentUserIDs: currentUserIdentitySet()
        )
    }

    @discardableResult
    private func applyMessageReactionDetail(_ extra: RemoteMessageExtra) -> Bool {
        conversationStore.applyMessageReactionDetail(extra) { extra, detailID in
            reactionDetail(from: extra, id: detailID)
        }
    }

    private func applyReactionReadStateIfNeeded(_ extra: RemoteMessageExtra) {
        conversationStore.applyReactionReadStateIfNeeded(extra, currentUserIDs: currentUserIdentitySet())
    }

    private func refreshMessageExtraFallback(_ extra: RemoteMessageExtra) {
        let channelID = extra.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelType = extra.channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty, !channelType.isEmpty else {
            scheduleRealtimeRecoveryRefresh(reason: "message_extra_missing_channel")
            return
        }
        guard let conversation = conversations.first(where: { $0.id == channelID || remoteChannelID(for: $0) == channelID }) else {
            scheduleRealtimeRecoveryRefresh(reason: "message_extra_unknown_channel")
            return
        }
        Task {
            syncConversationMessagesIfNeeded(conversation.id, force: true, silent: true)
            if let session = currentMessageSidecarSyncSession() {
                await syncConversationSidecars(channelID: channelID, channelType: channelType, session: session)
            }
        }
    }

    private func isMessageExtraAtOrBelowEffectiveRead(_ extra: RemoteMessageExtra) -> Bool {
        guard extra.channelSeq > 0 else { return false }
        let channelID = normalizedRemoteChannelID(extra.channelID, channelType: extra.channelType)
        let channelType = normalizedReadWatermarkChannelType(channelID: channelID, channelType: extra.channelType)
        let readStateKey = conversationReadStateKey(channelID: channelID, channelType: channelType)
        let readWatermarkScope = currentReadWatermarkScope(channelID: channelID, channelType: channelType)
        return conversationStore.isReadByEffectiveWatermark(
            channelSeq: extra.channelSeq,
            readStateKey: readStateKey,
            scope: readWatermarkScope
        )
    }

    private func decodeRealtimeEnvelopePayload<T: Decodable>(_ type: T.Type, envelope: RealtimeEnvelope) -> T? {
        let object = envelope.payload.mapValues(\.anyValue)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? realtimeDecoder.decode(T.self, from: data)
    }

}

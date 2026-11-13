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

    // WDT_IOS1_COLD_RESTORE_INITIAL_SCENE_ENTRY_20261111_BEGIN — Actual initial view-task call, initially an exact forwarding extraction.
    func appInitialSceneDidBecomeAvailable(isActive: Bool) {
        iosRiskTelemetrySceneDidBecomeAvailable(isActive: isActive)
        // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_BEGIN — Only consume a ready restore owned by the current authority.
        if isActive { resumePendingColdLaunchRealtimeAdmission() }
        // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_END
    }
    // WDT_IOS1_COLD_RESTORE_INITIAL_SCENE_ENTRY_20261111_END

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
        biometricAccessStore.revokeGrants() // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110
        iosRiskTelemetry.sceneDidBecomeInactive()
        iosRiskTelemetrySceneIsActive = false
        renderCallPromptEnvironment(.applicationDidEnterBackground)
    }

    func appDidEnterForeground() {
        refreshAppInteractionPolicy(force: true)
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
        isConversationListUserInteracting = false
		(api as? IMAPIClient)?.runtimeColdLaunchSceneDidEnterBackground()
        #if ACCESS_DIAGNOSTICS_OVERLAY_ENABLED
        GroupForegroundSessionClearDiagnostics.suspend()
        #endif
        biometricAccessStore.revokeGrants() // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110
        isApplicationBackgroundedForRTC = true
        // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log lock/background boundaries for RTC interface diagnosis only.
        logRTCLifecycleInterfaceEvent("background_lock")
        // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
        iosRiskTelemetry.sceneDidEnterBackground()
        iosRiskTelemetrySceneIsActive = false
        // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_BEGIN
        retireColdLaunchSessionRestoreAdmission()
        // WDT_IOS1_COLD_RESTORE_ADMISSION_BRIDGE_20261111_END
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

}

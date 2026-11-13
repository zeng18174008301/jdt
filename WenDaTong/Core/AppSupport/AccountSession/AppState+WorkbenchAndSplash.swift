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
    func enterIM(showToast: Bool = true) -> PostLoginWorkbenchAdmissionOutcome {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let admission = postLoginWorkbenchAdmission.consume(
            hasIMSession: context.hasIMSession,
            scope: scope
        )
        switch admission {
        case .rejectedMissingSession:
            launchSplashDismissTasks.cancel()
            bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            dismissSplashOverlay(reason: "post_login_missing_session", cancelTask: true)
            bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
            stopInboxRefreshLoop()
            stopRTCCallRefreshLoop()
            disconnectRealtime(shouldReconnect: false)
            resetAuthenticatedRemoteData(showLoading: false)
            disableAccessDiagnosticsOverlay()
            apiContext.clearSession(sessionStore: protectedSessionStore)
            setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
            loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话未完成，请重新登录")
            return admission
        case .duplicate:
            launchSplashDismissTasks.cancel()
            bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            dismissSplashOverlay(reason: "post_login_duplicate", cancelTask: true)
            return admission
        case .admitted:
            launchSplashDismissTasks.cancel()
            bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            dismissSplashOverlay(reason: "post_login_admitted", cancelTask: true)
	        }
	        beginMainShellBootstrapTrace(reason: "enter_im")
	        setAuthenticated(true) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
	        bindCallRecordPersistence(for: context)
	        activateMyInviteCodeForCurrentSession()
	        activeTab = .chats
        startSplashConfigurationRefresh(
            context: context,
            intent: .tenantEntry,
            reason: "enter_im"
        )
        startInboxRefreshLoop()
        startRTCCallRefreshLoop()
        startRealtimeConnection(context: context)
        replayDeferredNotificationOpensIfPossible()
        registerPendingStandardPushDeviceIfPossible(reason: "enter_im")
        registerPendingVoIPDeviceIfPossible(reason: "enter_im")
        if showToast {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已进入 \(currentEnterprise.name)")
        }
        return admission
    }

    func beginMainShellBootstrapTrace(reason: String) {
        mainShellBootstrapTrace.begin()
        print("[JHT Perf] main_shell_bootstrap_start reason=\(reason) scope=\(Self.sessionScopeLogToken(remoteDataScopeKey(for: apiContext)))")
    }

    nonisolated static func sessionScopeLogToken(_ rawScope: String) -> String {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { return "scope:empty" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in scope.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "scope:hash:\(String(hash, radix: 16).suffix(12))"
    }

    func noteMainShellAppeared() {
        ensureRTCSignalingRefreshActive(reason: "main_shell_appear")
        if splashConfigurationRefreshTask == nil,
           !didEvaluateInitialSplashOverlay,
           !pendingInitialSplashOverlayEvaluation,
           apiContext.hasIMSession {
            startSplashConfigurationRefresh(
                context: apiContext,
                intent: isShowingLaunchSplash ? .coldLaunch : .refreshOnly,
                reason: "main_shell_appear"
            )
        }
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                self?.noteMainShellInteractive(reason: "post_appear")
            }
        }
        guard let elapsed = mainShellBootstrapTrace.claimAppearance() else { return }
        print("[JHT Perf] main_shell_appeared_ms=\(elapsed) conversations=\(conversationStore.conversations.count) cached=\(hasLoadedRemoteSnapshot)")
    }

    func dismissSplashOverlay() {
        guard let presentation = activeSplashOverlay,
              presentation.canSkip() else {
            return
        }
        dismissSplashOverlay(reason: "skip", cancelTask: true)
    }

    func startSplashConfigurationRefresh(
        context: IMAPIContext,
        intent: SplashPresentationIntent,
        reason: String
    ) {
        guard context.hasIMSession,
              let splashScope = splashTenantScope(for: context) else {
            finishSplashPresentationIntent(
                intent,
                result: .noSession,
                trigger: reason,
                deadline: nil
            )
            return
        }
        let remoteScope = remoteDataScopeKey(for: context)
        guard isCurrentRemoteScope(remoteScope) else { return }

        splashConfigurationRefreshTask?.cancel()
        let generation = splashConfigurationRefreshGeneration.issueToken()
        let now = Date()
        let deadline = intent.presentationWindowSeconds.map { now.addingTimeInterval($0) }
        if intent.allowsPresentation {
            resetInitialSplashOverlayEvaluationState()
            initialSplashOverlayEvaluationStartedAt = now
            pendingInitialSplashOverlayEvaluation = true
            SplashSnapshotStore.disableSnapshot(
                scope: splashScope,
                reason: "refresh_pending"
            )
        }

        splashConfigurationRefreshTask = Task { @MainActor [weak self, context, splashScope, remoteScope, intent, reason, deadline] in
            guard let self else { return }
            defer {
                if self.splashConfigurationRefreshGeneration.isCurrent(generation) {
                    self.splashConfigurationRefreshTask = nil
                }
            }
            do {
                let remote = try await self.fetchScopedFileUploadConfig(context: context, scope: remoteScope)
                guard self.isCurrentSplashRefresh(
                    generation: generation,
                    scope: splashScope,
                    remoteScope: remoteScope
                ) else {
                    return
                }
                self.handleSplashConfiguration(
                    remote.splashConfiguration,
                    context: context,
                    scope: remoteScope,
                    source: "splash_refresh_\(reason)",
                    splashScope: splashScope,
                    intent: intent,
                    refreshGeneration: generation,
                    deadline: deadline
                )
            } catch {
                guard self.isCurrentSplashRefresh(
                    generation: generation,
                    scope: splashScope,
                    remoteScope: remoteScope
                ) else {
                    return
                }
                SplashSnapshotStore.disableSnapshot(
                    scope: splashScope,
                    reason: "refresh_failed"
                )
                self.finishSplashPresentationIntent(
                    intent,
                    result: .blockedByPolicy("refresh_failed"),
                    trigger: reason,
                    deadline: deadline
                )
                print("[JHT Splash] config_refresh_failed tenant=\(splashScope.tenantID) trigger=\(reason)")
            }
        }
    }

    func isCurrentSplashRefresh(
        generation: Int,
        scope: SplashTenantScope,
        remoteScope: String
    ) -> Bool {
        splashConfigurationRefreshGeneration.isCurrent(generation)
            && isCurrentRemoteScope(remoteScope)
            && splashTenantScope(for: apiContext) == scope
    }

    func prepareSplashForScopeChange(reason: String) {
        resetBatchForwardDraftForScopeChange()
        splashConfigurationRefreshTask?.cancel()
        splashConfigurationRefreshTask = nil
        splashConfigurationRefreshGeneration.invalidate()
        dismissSplashOverlay(reason: reason, cancelTask: true)
        resetInitialSplashOverlayEvaluationState()
    }

    func resetBatchForwardDraftForScopeChange() {
        invalidateBatchForwardSubmission()
        batchForwardStore.clear() // WDT_IOS1_REFACTOR_BATCH_FORWARD_OBSERVATION_20261110
    }

    func invalidateBatchForwardSubmission() {
        batchForwardSubmissionGeneration &+= 1
        batchForwardSubmissionTask?.cancel()
        batchForwardSubmissionTask = nil
    }

    func presentSplashIfAllowed(
        intent: SplashPresentationIntent,
        candidate: SplashRefreshCandidate,
        preparedImage: SplashPreparedImage,
        remoteScope: String,
        trigger: String,
        deadline: Date?
    ) {
        guard intent.allowsPresentation else { return }
        guard isCurrentSplashRefresh(
            generation: candidate.generation,
            scope: candidate.scope,
            remoteScope: remoteScope
        ),
        candidate.matches(
            currentGeneration: splashConfigurationRefreshGeneration.currentToken(),
            currentScope: splashTenantScope(for: apiContext),
            snapshot: SplashSnapshotStore.snapshot(scope: candidate.scope)
        ) else {
            return
        }
        let now = Date()
        guard deadline.map({ now <= $0 }) ?? true else {
            finishSplashPresentationIntent(
                intent,
                result: .blockedByPolicy("presentation_window_expired"),
                trigger: trigger,
                deadline: deadline
            )
            return
        }
        if intent == .coldLaunch {
            guard canPresentColdLaunchSplash(
                hasMainShellBecomeInteractive: hasMainShellBecomeInteractive
            ) else {
                finishSplashPresentationIntent(
                    intent,
                    result: .blockedByPolicy("main_shell_interactive"),
                    trigger: trigger,
                    deadline: deadline
                )
                return
            }
        }
        let result = evaluateSplashOverlay(
            reason: trigger,
            isColdStartLike: true,
            now: now,
            allowReplacingLaunchSplash: true,
            candidate: candidate,
            preparedImage: preparedImage
        )
        finishSplashPresentationIntent(
            intent,
            result: result,
            trigger: trigger,
            deadline: deadline
        )
    }

    func finishSplashPresentationIntent(
        _ intent: SplashPresentationIntent,
        result: SplashOverlayEvaluationResult,
        trigger: String,
        deadline: Date?
    ) {
        guard intent.allowsPresentation else { return }
        let now = Date()
        if intent == .coldLaunch {
            handleInitialSplashOverlayEvaluation(result, trigger: trigger, now: now)
            return
        }
        if result.keepsInitialEvaluationPending,
           deadline.map({ now <= $0 }) ?? false {
            pendingInitialSplashOverlayEvaluation = true
            return
        }
        didEvaluateInitialSplashOverlay = true
        pendingInitialSplashOverlayEvaluation = false
        print("[JHT Splash] scoped_overlay_evaluation_consumed result=\(result.reason) trigger=\(trigger)")
    }

    func evaluateForegroundSplashOverlayIfNeeded(now: Date = Date()) {
        guard let scope = splashTenantScope(for: apiContext) else { return }
        let displayState = SplashSnapshotStore.displayState(scope: scope)
        guard let lastBackgroundedAt = displayState.lastBackgroundedAt else { return }
        let elapsed = now.timeIntervalSince1970 - lastBackgroundedAt
        if elapsed < splashWarmThresholdSeconds {
            return
        }
        guard elapsed >= splashColdEquivalentThresholdSeconds else {
            return
        }
        startSplashConfigurationRefresh(
            context: apiContext,
            intent: .foregroundColdEquivalent,
            reason: "foreground_cold_equivalent"
        )
    }

    @discardableResult
    private func evaluateSplashOverlay(
        reason: String,
        isColdStartLike: Bool,
        now: Date = Date(),
        allowReplacingLaunchSplash: Bool = false,
        candidate: SplashRefreshCandidate,
        preparedImage: SplashPreparedImage
    ) -> SplashOverlayEvaluationResult {
        guard isColdStartLike else {
            return logSplashOverlaySkip(.notColdStartLike, tenantID: nil, trigger: reason)
        }
        guard isAuthenticated else {
            return logSplashOverlaySkip(.notAuthenticated, tenantID: nil, trigger: reason)
        }
        guard apiContext.hasIMSession else {
            return logSplashOverlaySkip(.noSession, tenantID: nil, trigger: reason)
        }
        guard activeSplashOverlay == nil else {
            return logSplashOverlaySkip(.overlayAlreadyActive, tenantID: activeSplashOverlay?.tenantID, trigger: reason)
        }
        guard let scope = splashTenantScope(for: apiContext),
              scope == candidate.scope else {
            return logSplashOverlaySkip(.noTenant, tenantID: nil, trigger: reason)
        }
        let tenantID = scope.tenantID
        guard let snapshot = SplashSnapshotStore.snapshot(scope: scope) else {
            return logSplashOverlaySkip(.notReadyNoSnapshot, tenantID: tenantID, trigger: reason)
        }
        guard candidate.matches(
            currentGeneration: splashConfigurationRefreshGeneration.currentToken(),
            currentScope: scope,
            snapshot: snapshot
        ) else {
            return logSplashOverlaySkip(.blockedByPolicy("stale_candidate"), tenantID: tenantID, trigger: reason)
        }
        guard snapshot.tenantID == tenantID else {
            return logSplashOverlaySkip(.blockedByPolicy("tenant_mismatch"), tenantID: tenantID, trigger: reason)
        }
        guard snapshot.isConfigDisplayable else {
            let policyReason = snapshot.disabledReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return logSplashOverlaySkip(.blockedByPolicy(policyReason.isEmpty ? "config_not_displayable" : policyReason), tenantID: tenantID, trigger: reason)
        }
        guard let cacheKey = snapshot.cacheKey(scope: scope) else {
            return logSplashOverlaySkip(.blockedByPolicy("missing_cache_key"), tenantID: tenantID, trigger: reason)
        }
        guard cacheKey == candidate.cacheKey,
              preparedImage.fileURL == SplashImageDiskCache.shared.fileURL(for: cacheKey) else {
            return logSplashOverlaySkip(.blockedByPolicy("prepared_image_mismatch"), tenantID: tenantID, trigger: reason)
        }
        let displayState = SplashSnapshotStore.displayState(scope: scope)
        guard displayState.canPresent(
            snapshot: snapshot,
            at: now,
            isColdStartLike: true,
            alreadyShownInThisLaunch: didPresentSplashInCurrentActivation
        ) else {
            return logSplashOverlaySkip(.blockedByPolicy("already_shown_in_activation"), tenantID: tenantID, trigger: reason)
        }
        if isShowingLaunchSplash, !allowReplacingLaunchSplash {
            return logSplashOverlaySkip(.launchSplashActive, tenantID: tenantID, trigger: reason)
        }

        let presentation = SplashOverlayPresentation(
            snapshot: snapshot,
            preparedImage: preparedImage,
            startedAt: now
        )
        didPresentSplashInCurrentActivation = true
        SplashSnapshotStore.recordShown(snapshot: snapshot, scope: scope, at: now)
        withAnimation(.easeOut(duration: 0.18)) {
            if isShowingLaunchSplash {
                launchSplashDismissTasks.cancel()
                bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
            }
            splashOverlayStore.present(presentation, at: now) // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110
        }
        scheduleSplashOverlayAutoDismiss(presentation)
        print("[JHT Splash] overlay_show tenant=\(tenantID) version=\(snapshot.normalizedVersion) trigger=\(reason) min_ms=\(presentation.minShowMS) max_ms=\(presentation.maxShowMS)")
        return .shown
    }

    @discardableResult
    private func logSplashOverlaySkip(_ result: SplashOverlayEvaluationResult, tenantID: String?, trigger: String) -> SplashOverlayEvaluationResult {
        let tenant = tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tenant, !tenant.isEmpty {
            print("[JHT Splash] overlay_skip tenant=\(tenant) reason=\(result.reason) trigger=\(trigger)")
        } else {
            print("[JHT Splash] overlay_skip reason=\(result.reason) trigger=\(trigger)")
        }
        return result
    }

    private func handleInitialSplashOverlayEvaluation(
        _ result: SplashOverlayEvaluationResult,
        trigger: String,
        now: Date = Date()
    ) {
        if result.keepsInitialEvaluationPending, isWithinInitialSplashOverlayRetryWindow(now: now) {
            pendingInitialSplashOverlayEvaluation = true
            return
        }
        didEvaluateInitialSplashOverlay = true
        pendingInitialSplashOverlayEvaluation = false
        print("[JHT Splash] initial_overlay_evaluation_consumed result=\(result.reason) trigger=\(trigger)")
    }

    private func isWithinInitialSplashOverlayRetryWindow(now: Date = Date()) -> Bool {
        guard let startedAt = initialSplashOverlayEvaluationStartedAt else { return false }
        return now.timeIntervalSince(startedAt) <= initialSplashOverlayRetryWindowSeconds
    }

    func resetInitialSplashOverlayEvaluationState() {
        didEvaluateInitialSplashOverlay = false
        pendingInitialSplashOverlayEvaluation = false
        initialSplashOverlayEvaluationStartedAt = nil
        didPresentSplashInCurrentActivation = false
    }

    private func scheduleSplashOverlayAutoDismiss(_ presentation: SplashOverlayPresentation) {
        splashOverlayDismissTask?.cancel()
        splashOverlayDismissTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let elapsedMS = max(
                    0,
                    Int((now.timeIntervalSince1970 - presentation.startedAt) * 1_000)
                )
                if elapsedMS >= presentation.maxShowMS {
                    break
                }
                // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
                let remainingMS = max(0, presentation.maxShowMS - elapsedMS)
                guard self?.splashOverlayStore.updateCountdown(
                    for: presentation.id,
                    remainingSeconds: max(1, Int(ceil(Double(remainingMS) / 1000.0))),
                    canSkip: presentation.canSkip(at: now)
                ) == true else { return }
                // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
            guard self?.activeSplashOverlay?.id == presentation.id else { return }
            self?.dismissSplashOverlay(reason: "auto", cancelTask: false)
        }
    }

    func dismissSplashOverlay(reason: String, cancelTask: Bool) {
        if cancelTask {
            splashOverlayDismissTask?.cancel()
        }
        splashOverlayDismissTask = nil
        // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
        guard activeSplashOverlay != nil else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            splashOverlayStore.clear()
        }
        // WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END
        print("[JHT Splash] overlay_dismiss reason=\(reason)")
    }

    func splashTenantScope(for context: IMAPIContext) -> SplashTenantScope? {
        let principalID = [
            context.accountID,
            context.imUID
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let tenantBaseURL = IMAPIClient.normalizedTenantAPIBaseURL(context.tenantAPIBaseURL)
            ?? api.tenantBase
        let tenantOrigin = SplashTenantScope.normalizedTenantAPIOrigin(
            tenantBaseURL.absoluteString
        )
        let scope = SplashTenantScope(
            appID: IMAPIContext.normalizedIOSAppID(context.appID),
            accountID: principalID,
            tenantID: context.tenantID ?? "",
            tenantOrigin: tenantOrigin
        )
        return scope.isValid ? scope : nil
    }

    private func noteMainShellInteractive(reason: String) {
		(api as? IMAPIClient)?.finishRuntimeColdLaunch()
        hasMainShellBecomeInteractive = true
        guard let elapsed = mainShellBootstrapTrace.claimInteractive() else { return }
        print("[JHT Perf] main_shell_interactive_ms=\(elapsed) reason=\(reason) conversations=\(conversationStore.conversations.count)")
    }

    func logout() {
        prepareSplashForScopeChange(reason: "logout")
        cancelRegistrationConfirmationPolling()
        clearRegistrationRecovery()
        pendingRegistrationReceiptStore.clear()
        registrationConfirmationStore.snapshot = .init() // WDT_IOS1_REFACTOR_REGISTRATION_CONFIRMATION_OBSERVATION_20261110
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        let logoutContext = apiContext
        retirePushDevices(for: logoutContext)
        clearPushRegistrationState()
        let rememberWasEnabled = rememberLoginCredentialsEnabledForAuthUI
        // A normal logout preserves committed remember-me credentials, but must
        // invalidate any in-flight login attempt before fencing its response.
        pendingRememberedLoginAttempt = nil
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(
            hasAuthenticatedSession: logoutContext.hasIMSession,
            product: "ios",
            appID: IMAPIContext.normalizedIOSAppID(logoutContext.appID),
            accountID: logoutContext.accountID,
            tenantID: logoutContext.tenantID,
            imUID: logoutContext.imUID
        )
        Task { [api] in
            await api.logoutAuthSessions(context: logoutContext)
        }
        let didScheduleLocalCleanup = removeRemoteSnapshotCache(for: logoutContext)
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        authFlowGeneration.invalidate()
        workspaceSwitchGeneration.invalidate()
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：退出登录清理临时企业码挑战
        clearLoginTenantCodeChallenge()
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        activeTab = .chats
        setAuthScreen(.welcome) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = "" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        resetForcedAppPolicyAuthState()
        clearTenantScopedSearchState(reason: "logout")
        disableAccessDiagnosticsOverlay()
        IMAPIContext.clearStoredSession(sessionStore: protectedSessionStore)
        apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        normalizeAuthScreenForCurrentAppPolicy()
        if rememberWasEnabled {
            rememberLoginPresentationStore.isEnabled = true // WDT_IOS1_REFACTOR_REMEMBER_LOGIN_PREFERENCE_OBSERVATION_20261110
        }
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(didScheduleLocalCleanup
            ? "已退出登录"
            : "本机数据安全清理失败，已阻止旧作用域缓存访问") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
    }

    @discardableResult
    func cancelCurrentAccount(reason: String? = nil) async -> Bool {
        let cancellationContext = apiContext
        guard cancellationContext.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return false
        }
        do {
            let result = try await api.cancelAccount(context: cancellationContext, reason: reason)
            guard result.cancelled else {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("账号注销失败，请稍后重试")
                return false
            }
            finishAccountCancellationLocally(context: cancellationContext)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("账号已注销")
            return true
        } catch {
            guard isCurrentRemoteScope(remoteDataScopeKey(for: cancellationContext)) else { return false }
            handleRemoteError(error, fallback: "账号注销失败")
            return false
        }
    }

    private func finishAccountCancellationLocally(context: IMAPIContext) {
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        clearRememberedLoginCredentials()
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        fileStore.cancelAttachmentDownloadTasks()
        cancelVoiceCallWatchdog()
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)
        releaseAudioSessionForVoiceCall()
        authFlowGeneration.invalidate()
        workspaceSwitchGeneration.invalidate()
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：账号注销清理临时企业码挑战
        clearLoginTenantCodeChallenge()
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        prepareSplashForScopeChange(reason: "account_cancelled")
        clearPushRegistrationState()
        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        activeTab = .chats
        setAuthScreen(.welcome) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = "" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        resetForcedAppPolicyAuthState()
        clearTenantScopedSearchState(reason: "account_cancelled")
        removeRemoteSnapshotCache(for: context)
        disableAccessDiagnosticsOverlay()
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true, sessionStore: protectedSessionStore)
        apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
        setCurrentEnterprise(Enterprise(id: "pending", name: "正在同步企业", code: "", role: "", status: "同步中", memberCount: 0, isDefault: false, accentHex: 0x5D6BFF)) // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
        setCurrentUser(IMUser(id: "pending", name: "正在同步", title: "", department: "", phone: "", email: "", status: "同步中", enterprise: "正在同步企业", avatarSeed: 0x5D6BFF, badges: [])) // WDT_IOS1_REFACTOR_CURRENT_USER_OBSERVATION_20261110
        resetAuthenticatedRemoteData(showLoading: false)
        normalizeAuthScreenForCurrentAppPolicy()
        remoteSyncEngine.clearRemoteErrorToastThrottle()
    }

    func handleCurrentDeviceRevoked() {
        guard isAuthenticated || apiContext.hasIMSession || apiContext.hasRefreshSession else { return }
        guard deviceRevocationHandling.begin() else { return }
        defer { deviceRevocationHandling.finish() }
        let revokedContext = apiContext
        clearPushRegistrationState()

        clearRememberedLoginCredentials()
        purgeCertificationIdentityRoot(rebindCurrentScope: false)
        prepareSplashForScopeChange(reason: "device_revoked")
        authFlowGeneration.invalidate()
        workspaceSwitchGeneration.invalidate()
        invalidatePreAuthEnterpriseContext(normalizeScreen: false)
        // JHT_MOD_BEGIN LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改开始：设备吊销清理临时企业码挑战
        clearLoginTenantCodeChallenge()
        // JHT_MOD_END LOGIN_TENANT_CODE_CHALLENGE_20260913 - 修改结束
        authenticationPresentationStore.isLoading = false // WDT_IOS1_REFACTOR_AUTH_LOADING_OBSERVATION_20261110
        bootstrapPresentationStore.launch.isRestoringSession = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
        remoteSyncEngine.cancelAuthSessionRefreshTask()
        coldLaunchSessionRecoveryTask?.cancel()
        coldLaunchSessionRecoveryTask = nil
        remoteSyncEngine.cancelRealtimeRecoveryTasks()
        conversationStore.cancelAllWarmRefreshTasks()
        fileStore.cancelAttachmentDownloadTasks()
        cancelVoiceCallWatchdog()
        stopInboxRefreshLoop()
        stopRTCCallRefreshLoop()
        disconnectRealtime(shouldReconnect: false)

        setAuthenticated(false) // WDT_IOS1_REFACTOR_AUTH_SESSION_OBSERVATION_20261110
        activeTab = .chats
        setAuthScreen(.accountLogin) // WDT_IOS1_REFACTOR_AUTH_ROUTING_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.message = nil // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        loginWorkspacePresentationStore.snapshot.defaultWorkspaceID = "" // WDT_IOS1_REFACTOR_LOGIN_WORKSPACE_OBSERVATION_20261110
        resetForcedAppPolicyAuthState()
        clearTenantScopedSearchState(reason: "device_revoked")
        removeRemoteSnapshotCache(for: revokedContext)
        disableAccessDiagnosticsOverlay()
        IMAPIContext.clearStoredSession(resetDeviceIdentity: true, sessionStore: protectedSessionStore)
        apiContext = IMAPIContext.load(sessionStore: protectedSessionStore)
        resetAuthenticatedRemoteData(showLoading: false)
        normalizeAuthScreenForCurrentAppPolicy()
        remoteSyncEngine.clearRemoteErrorToastThrottle()
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(DeviceRevocationDetector.logoutMessage)
    }

}

// WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_BEGIN
@MainActor
final class SplashOverlayStore {
    struct Snapshot: Equatable {
        var presentation: SplashOverlayPresentation?
        var remainingSeconds = 0
        var canSkip = false
    }

    @Published private(set) var snapshot = Snapshot()

    func updates<Value: Equatable>(_ project: @escaping (Snapshot) -> Value) -> AnyPublisher<Value, Never> {
        $snapshot.map(project).removeDuplicates().eraseToAnyPublisher()
    }

    func present(_ presentation: SplashOverlayPresentation, at date: Date) {
        snapshot = Snapshot(
            presentation: presentation,
            remainingSeconds: max(1, Int(ceil(Double(presentation.maxShowMS) / 1000.0))),
            canSkip: presentation.canSkip(at: date)
        )
    }

    func updateCountdown(for presentationID: String, remainingSeconds: Int, canSkip: Bool) -> Bool {
        guard snapshot.presentation?.id == presentationID else { return false }
        if snapshot.remainingSeconds != remainingSeconds || snapshot.canSkip != canSkip {
            snapshot = Snapshot(
                presentation: snapshot.presentation,
                remainingSeconds: remainingSeconds,
                canSkip: canSkip
            )
        }
        return true
    }

    func clear() {
        if snapshot.presentation != nil {
            snapshot = Snapshot()
        }
    }
}
// WDT_IOS1_REFACTOR_SPLASH_OVERLAY_OBSERVATION_20261110_END // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

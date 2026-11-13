import Foundation
import Combine
import SwiftUI // WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110

extension AppState {
    // WDT_IOS1_REFACTOR_CONVERSATION_RELAY_RETIREMENT_20261110: Domain Stores publish directly to their presentation consumers.
    func bindDeviceRevocationNotifications() {
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_BEGIN — The sole producer is MainActor request execution; consume before its error unwinds.
        NotificationCenter.default.publisher(for: .imCurrentDeviceRevoked)
            .sink { [weak self] notification in
                guard let self, let original = notification.object as? IMAuthSessionFence,
                      self.apiContext.isSameAuthAuthority(as: original) else { return }
                self.handleCurrentDeviceRevoked()
            }
        // WDT_IOS1_REQUEST_DEVICE_AUTHORITY_20261111_END
            .store(in: &storeCancellables)
    }

}

// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_BEGIN
extension AppState {
    func reconcileAPIContextChange(from oldValue: IMAPIContext) {
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        (api as? IMAPIClient)?.updateHTTPRouteSession(apiContext)
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
        // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_BEGIN
        if oldValue.hasIMSession != apiContext.hasIMSession
            || callRecordRuntimeScope(for: oldValue) != callRecordRuntimeScope(for: apiContext) {
            // Detach before any new-principal callback can persist old rows.
            callStore.clearCallRecordPersistenceBinding()
        }
        // WDT_IOS1_CALL_ARCHIVE_RUNTIME_SCOPE_20261112_END
        if IMAPIContext.normalizedIOSAppID(oldValue.appID) != IMAPIContext.normalizedIOSAppID(apiContext.appID)
            || oldValue.deviceID != apiContext.deviceID {
            cancelRegistrationSessionRecovery()
        }
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_BEGIN
        biometricAccessStore.replaceSettings(BiometricProtectionStore.load(
            context: apiContext,
            defaults: biometricDefaults
        ))
        // WDT_IOS1_REFACTOR_BIOMETRIC_ACCESS_OBSERVATION_20261110_END
        tenantClientPolicyStore.setActiveScope(remoteDataScopeKey(for: apiContext)) // WDT_IOS1_REFACTOR_TENANT_CLIENT_POLICY_OBSERVATION_20261110
        updateTenantInteractionPresentationScope() // WDT_IOS1_REFACTOR_TENANT_INTERACTION_OBSERVATION_20261110
        reconcileTenantContextRoleAuthority(from: oldValue, to: apiContext)
        reconcileTenantDevicePolicyAuthority(from: oldValue, to: apiContext)
        reconcileMyInviteCodeAuthority(from: oldValue, to: apiContext)
        reconcileCertificationIdentityScope(from: oldValue, to: apiContext)
        reconcileAvatarRealtimeScope(from: oldValue, to: apiContext)
        reconcilePresenceConnectivityScope(from: oldValue, to: apiContext)
        reconcileStickerMessageAssetAuthority(from: oldValue, to: apiContext) // WDT_IOS1_REFACTOR_STICKER_MESSAGE_ASSET_OBSERVATION_20261110
        reconcileCurrentProfileAuthorityScope(from: oldValue, to: apiContext)
        reconcileLocalMessageScope(from: oldValue, to: apiContext)
        if sessionReauthenticationCommit == nil,
           oldValue.authSessionFence != apiContext.authSessionFence,
           isSessionReauthenticationPresented {
            cancelSessionReauthentication()
        }
        if RememberedLoginCredentialScope(context: oldValue) != RememberedLoginCredentialScope(context: apiContext) {
            pendingRememberedLoginAttempt = nil
            reloadRememberedLoginCredentialsForCurrentScope()
        }
        let previousPhoneBindingScope = PhoneBindingChallengeSessionScope(context: oldValue)
        let currentPhoneBindingScope = PhoneBindingChallengeSessionScope(context: apiContext)
        if previousPhoneBindingScope != currentPhoneBindingScope {
            invalidatePhoneBindingChallenge(ownedBy: previousPhoneBindingScope)
        }
        // WDT_RTC_IOS1_AUTODROP_20260921_BEGIN: refresh cleanup credentials before direct-call invalidation checks.
        reconcileDirectCallCleanupContexts(from: oldValue, to: apiContext)
        // WDT_RTC_IOS1_AUTODROP_20260921_END
        if DirectCallContextBinding(context: oldValue) != DirectCallContextBinding(context: apiContext) {
            if oldValue.accountID != apiContext.accountID
                || oldValue.sessionEpoch != apiContext.sessionEpoch
                || callLicenseScopeKey(for: oldValue) != callLicenseScopeKey(for: apiContext) {
                fileStore.invalidateCallLicenseAuthority() // WDT_IOS1_REFACTOR_UPLOAD_CONFIG_AUTHORITY_20261110
            }
            rtcCapabilityAlertStore.message = nil // WDT_IOS1_REFACTOR_RTC_CAPABILITY_ALERT_OBSERVATION_20261110
            advanceDirectCallCapabilityGeneration(
                for: .voice,
                reason: "call_session_changed"
            )
            advanceDirectCallCapabilityGeneration(
                for: .video,
                reason: "call_session_changed"
            )
            resetRTCDeviceCapabilityReportState()
            scheduleIOSRiskTelemetryContextSync()
        }
        reconcileRTCMediaStateHeartbeatContextChange(from: oldValue, to: apiContext)
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    }

    func configureRealtimeClient() {
        realtimeClient.canReconnect = { [weak self] in
            guard let self else { return false }
            return self.iosRiskTelemetrySceneIsActive
                && self.isAuthenticated
                && self.apiContext.hasIMSession
        }
        realtimeClient.connectionRequestProvider = { [weak self] in
            guard let self,
                  self.isAuthenticated else {
                return nil
            }
            let context = self.apiContext
            let scope = self.remoteDataScopeKey(for: context)
            guard context.hasIMSession,
                  self.isCurrentRemoteScope(scope),
                  let request = self.realtimeConnectionRequest(context: context) else {
                return nil
            }
            return request
        }
        realtimeClient.onConnectionUnavailable = { [weak self] in
            #if DEBUG
            if self?.authPolicyScreenshotModeEnabled == true { return }
            #endif
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self?.setToast("实时连接地址不可用")
        }
        realtimeClient.onConnectionStateChanged = { [weak self] connected in
            self?.isRealtimeConnected = connected
        }
        realtimeClient.onConnected = { [weak self] in
            guard let self else { return }
			(self.api as? IMAPIClient)?.recordRuntimeRealtimeConnected(context: self.apiContext)
            self.handleAvatarRealtimeOutcome(
                self.avatarRealtimeProjection.requireAuthorityAfterReconnect()
            )
            self.queueAvatarAuthorityRefetch(self.visibleAvatarAuthorityUIDs())
            self.fileStore.noteMediaNetworkRecovery() // WDT_IOS1_REFACTOR_MEDIA_NETWORK_RECOVERY_OBSERVATION_20261110
            self.accessDiscovery.markActiveRealtimeEndpointConnected()
            self.scheduleRealtimeEndpointStableConfirmation()
            self.recordAccessDiagnosticsRealtimeConnected()
            DebugConsoleDiagnostics.trace("[JHT Realtime] app_connect_ack fallback=\(self.redactedRealtimeURLSummary(self.api.webSocketURL(context: self.apiContext)))")
            self.clearRealtimeReconnectNotice()
            self.resubscribeRealtimeChannels()
            if let ticket = self.localMessageTicket {
                self.scheduleDurableReadAckRecovery(ticket: ticket, runImmediately: true)
            }
            self.scheduleRealtimeRecoveryRefresh(reason: "connect_ack")
            self.scheduleActiveConversationRecoveryAfterRealtimeConnected(reason: "connect_ack")
        }
        realtimeClient.onDisconnected = { [weak self] in
            #if DEBUG
            if self?.authPolicyScreenshotModeEnabled == true { return }
            #endif
            self?.invalidateRealtimeEndpointStableConfirmation()
            self?.accessDiscovery.markActiveRealtimeEndpointFailed()
            self?.scheduleRealtimeReconnectToastIfNeeded()
        }
        if let concreteRealtimeClient = realtimeClient as? RealtimeClient {
            AccessDiagnostics.shared.bindConnectionDiagnostics(to: concreteRealtimeClient)
			concreteRealtimeClient.onRouteFailure = { [weak self] error in
				guard let self, let api = self.api as? IMAPIClient else { return }
				api.recordRuntimeRealtimeFailure(error, context: self.apiContext)
			}
            concreteRealtimeClient.onQUICFallbackToWebSocket = { [weak self] _ in
                guard let self else { return }
                self.invalidateRealtimeEndpointStableConfirmation()
                self.accessDiscovery.markActiveRealtimeEndpointFailed()
                self.recordAccessDiagnosticsRealtimeFallback(context: self.apiContext, reason: "QUIC 失败，回落 WSS")
            }
        }
        realtimeClient.onReconnectAttempt = { [weak self] in
            guard let self else { return }
            if !self.usesLocalRealtimeFallback(context: self.apiContext) {
                self.scheduleAccessDiscoveryRefresh(context: self.apiContext, reason: "reconnect")
            }
            self.scheduleRealtimeRecoveryRefresh(reason: "reconnect")
        }
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
        (realtimeClient as? RealtimeClient)?.captureIncomingAdmission = { [weak self] in
            self?.captureRealtimeIngestAdmission() ?? { .appScopeRejected }
        }
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
        realtimeClient.onEnvelope = { [weak self] envelope in
            self?.handleRealtimeEnvelope(envelope)
        }
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
        (realtimeClient as? RealtimeClient)?.onSerialEnvelope = { [weak self] envelope, diagnostic, delivery in
            await self?.handleRealtimeEnvelopeSerial(envelope, diagnostic: diagnostic, delivery: delivery)
        }
        // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END
    }

    func scheduleLaunchSplashDismiss() {
        launchSplashDismissTasks.replace(with: Task { [weak self] in
            try? await Task.sleep(nanoseconds: 950_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    self.bootstrapPresentationStore.launch.isShowingLaunchSplash = false // WDT_IOS1_REFACTOR_BOOTSTRAP_SYNC_OBSERVATION_20261110
                }
            }
        })
    }
}
// WDT_IOS1_REFACTOR_APPSTATE_MEMBERSHIP_SPLIT_20261110_END

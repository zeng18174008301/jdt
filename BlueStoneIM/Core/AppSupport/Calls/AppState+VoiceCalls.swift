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

// MARK: - AppState MainActor Partition
//
// Voice call orchestration stays on AppState/MainActor because it coordinates
// CallStore, active/incoming call presentation, RTC provider/license state,
// media lifecycle tasks, CallKit/system audio transitions, realtime call events,
// and SwiftUI-observed call state. Transport models and lower-level media clients
// remain outside AppState; this file keeps the UI/state boundary explicit while
// preserving the original call flow ordering.

// MARK: - Voice Calls

extension AppState {
    private var hasTruthfulCallOwnership: Bool {
        callStore.hasTruthfulCall
    }

    private func renderCallLifecycleTransition(_ transition: CallLifecycleTransition?) {
        guard let transition else { return }
        SystemNotificationSound.render(callStore.promptCommands(for: transition))
    }

    func renderCallPromptEnvironment(_ event: CallPromptEnvironmentEvent) {
        SystemNotificationSound.render(callStore.promptCommands(for: event))
    }

    @discardableResult
    private func claimCallLifecycle(
        callID: String,
        direction: CallLifecycleDirection,
        stateVersion: Int64 = 0,
        reason: String
    ) -> Bool {
        if direction == .outgoing {
            SystemNotificationSound.setOutgoingRingbackSuppressed(false)
        }
        guard let transition = callStore.claimLifecycle(
            scopeID: remoteDataScopeKey(for: apiContext),
            callID: callID,
            direction: direction,
            stateVersion: stateVersion,
            reason: reason
        ) else {
            return false
        }
        renderCallLifecycleTransition(transition)
        return transition.isApplied
    }

    @discardableResult
    private func advanceCallLifecycle(
        callID: String,
        to phase: CallLifecyclePhase,
        stateVersion: Int64? = nil,
        reason: String = ""
    ) -> Bool {
        let direction = callStore.activeLifecycleSnapshot?.direction
        guard let transition = callStore.advanceLifecycle(
            callID: callID,
            to: phase,
            stateVersion: stateVersion,
            reason: reason
        ) else {
            return false
        }
        renderCallLifecycleTransition(transition)
        if transition.isApplied, phase == .connected, direction == .outgoing {
            voiceCallSystem.reportOutgoingCallConnected(callID: callID)
        }
        return transition.isApplied
    }

    func releaseCallLifecycle(
        as phase: CallLifecyclePhase = .ended,
        reason: String
    ) {
        renderCallLifecycleTransition(callStore.releaseLifecycle(as: phase, reason: reason))
    }

    private func discardUnownedLegacyCallViews(reason: String) {
        guard !hasTruthfulCallOwnership,
              activeVoiceCall != nil || incomingVoiceCall != nil else { return }
        voiceDebug("call_view_discard reason=\(reason)")
        stopCallMediaSession(for: activeVoiceCall, reason: reason)
        activeVoiceCall = nil
        incomingVoiceCall = nil
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopAllCallPrompts()
    }

    private func releaseAbandonedCallOwnershipBeforeIncoming(callID: String) {
        let nextCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextCallID.isEmpty,
              activeVoiceCall == nil,
              incomingVoiceCall == nil,
              let lifecycle = callStore.activeLifecycleSnapshot else {
            return
        }
        let ownedCallID = lifecycle.identity.callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ownedCallID.isEmpty, ownedCallID != nextCallID else { return }
        voiceDebug(
            "call_owner_release reason=abandoned_before_next_incoming previous=\(Self.shortDebugID(ownedCallID)) next=\(Self.shortDebugID(nextCallID))"
        )
        releaseCallLifecycle(as: .ended, reason: "abandoned_before_next_incoming")
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopAllCallPrompts()
    }

    func bindCallAudioLifecycleNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        callAudioLifecycleObserverTokens.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor in
                    guard let self else { return }
                    guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                    if type == .began {
                        self.renderCallPromptEnvironment(.interruptionBegan)
                    } else {
                        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                        self.renderCallPromptEnvironment(.interruptionEnded(shouldResume: shouldResume))
                        if shouldResume {
                            // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始：音频中断恢复时，纯语音通话也需要恢复 WebRTC 音频会话
                            self.reconcileActiveCallAudioSession(reason: "interruption_ended")
                            // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束
                        }
                    }
                }
            }
        )
        callAudioLifecycleObserverTokens.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    guard let self else { return }
                    let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    self.handleCallAudioRouteChange(reason)
                }
            }
        )
        callAudioLifecycleObserverTokens.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.renderCallPromptEnvironment(.mediaServicesReset)
                    // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始
                    self?.reconcileActiveCallAudioSession(reason: "media_services_reset")
                    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束
                }
            }
        )
        callAudioLifecycleObserverTokens.append(
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.renderCallPromptEnvironment(.applicationWillTerminate) }
            }
        )
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: category/override notifications are consequences of our own configuration.
    func handleCallAudioRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        let projected: CallPromptRouteChangeReason
        switch reason {
        case .newDeviceAvailable: projected = .newDeviceAvailable
        case .oldDeviceUnavailable: projected = .oldDeviceUnavailable
        default: return
        }
        renderCallPromptEnvironment(.audioRouteChanged(projected))
        reconcileActiveCallAudioSession(reason: "route_changed")
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始：保留视频原恢复逻辑，同时为纯语音补齐音频会话恢复
    private func reconcileActiveCallAudioSession(reason: String) {
        guard let call = activeVoiceCall,
              let callID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !callID.isEmpty else { return }
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：记录恢复时 CallKit 音频激活状态，只做诊断不改变现有恢复策略
        // WDT_IOS1_AUDIO_ROUTE_20260921: distinguish replacements even when the server call ID is reused.
        let localSessionID = call.id
        let callKitAudioActive = voiceCallSystemAudioSessionActive
        let callKitAudioGeneration = voiceCallSystemAudioSessionGeneration
        voiceDebug("audio_reconcile reason=\(reason) call=\(Self.shortDebugID(callID)) video=\(call.isVideoCall) callkitAudioActive=\(callKitAudioActive) callkitAudioGen=\(callKitAudioGeneration)")
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        if call.isVideoCall {
            Task { [weak self, videoMediaClient] in
                // WDT_IOS1_AUDIO_ROUTE_20260921: discard old reconciliation tasks after hangup/replacement.
                guard let self, !self.isEndingActiveCall, self.activeVoiceCall?.callID == callID, self.activeVoiceCall?.id == localSessionID,
                      self.activeVoiceCall?.isVideoCall == true else { return }
                do {
                    try await videoMediaClient.reconcileAudioSessionAfterSystemEvent()
                } catch {
                    guard self.activeVoiceCall?.callID == callID else { return }
                    self.toast = reason == "media_services_reset"
                        ? "视频通话音频服务恢复失败，请结束后重试"
                        : "视频通话音频路由恢复失败"
                }
            }
            return
        }
        let speakerOn = call.speakerOn
        Task { [weak self, voiceMediaClient] in
            // WDT_IOS1_AUDIO_ROUTE_20260921: discard old reconciliation tasks after hangup/replacement.
            guard let self, !self.isEndingActiveCall, self.activeVoiceCall?.callID == callID, self.activeVoiceCall?.id == localSessionID,
                  self.activeVoiceCall?.isVideoCall != true else { return }
            do {
                try await voiceMediaClient.reconcileAudioSessionAfterSystemEvent(speakerOn: speakerOn)
            } catch {
                guard self.activeVoiceCall?.callID == callID, self.activeVoiceCall?.id == localSessionID,
                      self.activeVoiceCall?.isVideoCall != true else { return }
                self.toast = reason == "media_services_reset"
                    ? "语音通话音频服务恢复失败，请结束后重试"
                    : "语音通话音频路由恢复失败"
            }
        }
    }

    private func reconcileActiveVideoAudioSession(reason: String) {
        reconcileActiveCallAudioSession(reason: reason)
    }
    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束

    func directCallCapabilityGeneration(for kind: DirectCallCapabilityKind) -> UInt64 {
        directCallCapabilityGenerations[kind, default: 0]
    }

    func currentDirectCallAttempt(for kind: DirectCallCapabilityKind) -> DirectCallAttempt? {
        directCallAttempts[kind]
    }

    private func clearCurrentDirectCallAttempt(
        kind: DirectCallCapabilityKind,
        operationID: UUID? = nil
    ) {
        guard operationID == nil || directCallAttempts[kind]?.operationID == operationID else { return }
        directCallAttempts.removeValue(forKey: kind)
    }

    func advanceDirectCallCapabilityGeneration(
        for kind: DirectCallCapabilityKind,
        reason: String
    ) {
        let invalidatedAttempt = currentDirectCallAttempt(for: kind)
        directCallCapabilityGenerations[kind, default: 0] &+= 1
        directCallAttempts.removeValue(forKey: kind)
        switch kind {
        case .voice:
            isStartingVoiceCall = false
        case .video:
            callStore.videoCallStartGeneration = nil
            isStartingVideoCall = false
            if reason == "call_session_changed",
               videoCallPreview?.isStartingCall == true {
                videoCallPreview?.isStartingCall = false
                videoCallPreview?.startError = "登录状态已变化，请重新打开视频通话"
            }
        }
        guard reason == "call_session_changed",
              let invalidatedAttempt,
              let incoming = incomingVoiceCall,
              incoming.isVideo == (kind == .video),
              incoming.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == invalidatedAttempt.callID,
              incoming.caller.id == invalidatedAttempt.peerID else {
            return
        }
        incomingVoiceCall = nil
    }

    func clearPendingIncomingCallForLicenseRevocation(
        kind: DirectCallCapabilityKind
    ) {
        guard let incoming = incomingVoiceCall,
              incoming.isVideo == (kind == .video) else {
            return
        }
        let callID = incoming.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = advanceCallLifecycle(callID: callID, to: .failure, reason: "license_revoked")
        incomingVoiceCall = nil
    }

    private func beginDirectCallAttempt(
        kind: DirectCallCapabilityKind,
        context: IMAPIContext,
        callID: String = "",
        peerID: String,
        mediaMode: String
    ) -> DirectCallAttempt {
        let attempt = DirectCallAttempt(
            kind: kind,
            context: DirectCallContextBinding(context: context),
            capabilityGeneration: directCallCapabilityGeneration(for: kind),
            callID: callID.trimmingCharacters(in: .whitespacesAndNewlines),
            peerID: peerID.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaMode: mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            operationID: UUID()
        )
        transferDirectCallCleanupObligationIfPresent(to: attempt)
        directCallAttempts[kind] = attempt
        claimDirectCallResourceIfPresent(attempt)
        return attempt
    }

    private func rebindDirectCallAttempt(
        _ attempt: DirectCallAttempt,
        callID: String? = nil,
        mediaMode: String? = nil
    ) throws -> DirectCallAttempt {
        try ensureDirectCallAttemptIsCurrent(attempt)
        let previousCallID = normalizedDirectCallID(attempt.callID)
        let rebound = DirectCallAttempt(
            kind: attempt.kind,
            context: attempt.context,
            capabilityGeneration: attempt.capabilityGeneration,
            callID: (callID ?? attempt.callID).trimmingCharacters(in: .whitespacesAndNewlines),
            peerID: attempt.peerID,
            mediaMode: (mediaMode ?? attempt.mediaMode)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            operationID: attempt.operationID
        )
        directCallAttempts[attempt.kind] = rebound
        if !previousCallID.isEmpty,
           previousCallID != normalizedDirectCallID(rebound.callID),
           directCallResourceOwners[previousCallID] == attempt {
            directCallResourceOwners.removeValue(forKey: previousCallID)
        }
        claimDirectCallResourceIfPresent(rebound)
        return rebound
    }

    private func normalizedDirectCallID(_ callID: String) -> String {
        callID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func claimDirectCallResourceIfPresent(_ attempt: DirectCallAttempt) {
        let callID = normalizedDirectCallID(attempt.callID)
        guard !callID.isEmpty else { return }
        directCallResourceOwners[callID] = attempt
    }

    private func transferDirectCallCleanupObligationIfPresent(
        to attempt: DirectCallAttempt
    ) {
        let callID = normalizedDirectCallID(attempt.callID)
        guard !callID.isEmpty,
              let obligation = directCallCleanupObligations[callID] else {
            return
        }
        directCallCleanupObligations[callID] = obligation.transferred(to: attempt)
    }

    // WDT_RTC_IOS1_AUTODROP_20260921_BEGIN: keep call ownership stable while using latest same-session credentials.
    func reconcileDirectCallCleanupContexts(from oldContext: IMAPIContext, to newContext: IMAPIContext) {
        // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: retain the last credentials of the resource's own login.
        let oldBinding = DirectCallContextBinding(context: oldContext)
        let latest = newContext.hasIMSession && DirectCallContextBinding(context: newContext) == oldBinding
            ? newContext : oldContext
        for key in directCallCleanupObligations.keys {
            guard DirectCallContextBinding(context: directCallCleanupObligations[key]?.context ?? oldContext) == oldBinding else { continue }
            directCallCleanupObligations[key]?.context = latest
        }
        for key in pendingRTCTerminalCompensations.keys {
            guard DirectCallContextBinding(context: pendingRTCTerminalCompensations[key]?.context ?? oldContext) == oldBinding else { continue }
            pendingRTCTerminalCompensations[key]?.context = latest
        }
        // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END
    }

    private func currentDirectCallRequestContext(
        _ original: IMAPIContext,
        attempt: DirectCallAttempt? = nil
    ) throws -> IMAPIContext {
        try Task.checkCancellation()
        let current = apiContext
        guard current.hasIMSession else { throw CancellationError() }
        let binding = attempt?.context ?? DirectCallContextBinding(context: original)
        guard DirectCallContextBinding(context: current) == binding else {
            throw CancellationError()
        }
        return current
    }

    private func directCallCleanupContext(_ stored: IMAPIContext) -> IMAPIContext {
        let current = apiContext
        guard current.hasIMSession,
              DirectCallContextBinding(context: current) == DirectCallContextBinding(context: stored) else {
            return stored
        }
        return current
    }
    // WDT_RTC_IOS1_AUTODROP_20260921_END

    private func registerAcceptedDirectCallCleanupObligation(
        context: IMAPIContext,
        callID: String,
        attempt: DirectCallAttempt
    ) {
        let callID = normalizedDirectCallID(callID)
        guard !callID.isEmpty,
              directCallResourceIsOwned(callID: callID, by: attempt) else {
            return
        }
        directCallCleanupObligations = directCallCleanupObligations.filter {
            $0.value.responsibleOperationID != attempt.operationID
        }
        directCallCleanupObligations[callID] = DirectCallCleanupObligation(
            callID: callID,
            // WDT_IOS1_CLEANUP_CREDENTIALS_20260921: accept may finish after this login refreshed.
            context: directCallCleanupContext(context),
            sourceAttempt: attempt,
            responsibleOperationID: attempt.operationID
        )
    }

    private func resolveDirectCallCleanupObligations(
        for attempt: DirectCallAttempt
    ) {
        directCallCleanupObligations = directCallCleanupObligations.filter {
            $0.value.responsibleOperationID != attempt.operationID
        }
    }

    private func abandonDirectCallSetup(_ attempt: DirectCallAttempt) {
        let obligations = directCallCleanupObligations.values.filter {
            $0.responsibleOperationID == attempt.operationID
        }
        for obligation in obligations {
            directCallCleanupObligations.removeValue(forKey: obligation.callID)
        }
        let ownedCallIDs = directCallResourceOwners.compactMap { callID, owner in
            owner.operationID == attempt.operationID ? callID : nil
        }
        for callID in ownedCallIDs {
            directCallResourceOwners.removeValue(forKey: callID)
        }
        clearCurrentDirectCallAttempt(
            kind: attempt.kind,
            operationID: attempt.operationID
        )
        guard !obligations.isEmpty else { return }
        for obligation in obligations {
            enqueueRTCTerminalCompensation(
                callID: obligation.callID,
                action: .hangup,
                reason: "replacement_setup_failed",
                context: obligation.context
            )
        }
    }

    private func releaseDirectCallTracking(callID: String) {
        let callID = normalizedDirectCallID(callID)
        guard !callID.isEmpty else { return }
        let owner = directCallResourceOwners.removeValue(forKey: callID)
        directCallCleanupObligations.removeValue(forKey: callID)
        if let owner {
            clearCurrentDirectCallAttempt(
                kind: owner.kind,
                operationID: owner.operationID
            )
            directCallCleanupObligations = directCallCleanupObligations.filter {
                $0.value.responsibleOperationID != owner.operationID
            }
        } else {
            for kind in [DirectCallCapabilityKind.voice, .video]
            where normalizedDirectCallID(directCallAttempts[kind]?.callID ?? "") == callID {
                directCallAttempts.removeValue(forKey: kind)
            }
        }
    }

    private func directCallResourceIsOwned(
        callID: String,
        by attempt: DirectCallAttempt
    ) -> Bool {
        let callID = normalizedDirectCallID(callID)
        return !callID.isEmpty && directCallResourceOwners[callID] == attempt
    }

    private func clearActiveDirectCallResourceIfOwned(
        callID: String,
        by attempt: DirectCallAttempt,
        reason: String
    ) {
        guard directCallResourceIsOwned(callID: callID, by: attempt),
              activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines)
                == normalizedDirectCallID(callID) else {
            return
        }
        stopCallMediaSession(for: activeVoiceCall, reason: reason)
        _ = advanceCallLifecycle(callID: callID, to: .failure, reason: reason)
        activeVoiceCall = nil
    }

    private func hangupDirectCallResourceIfOwned(
        context: IMAPIContext,
        callID: String,
        by attempt: DirectCallAttempt,
        reason: String
    ) async {
        let callID = normalizedDirectCallID(callID)
        guard directCallResourceIsOwned(callID: callID, by: attempt) else { return }
        let cleanupContext: IMAPIContext
        if let obligation = directCallCleanupObligations[callID],
           obligation.responsibleOperationID == attempt.operationID {
            cleanupContext = directCallCleanupContext(obligation.context)
            directCallCleanupObligations.removeValue(forKey: callID)
        } else {
            cleanupContext = directCallCleanupContext(context)
        }
        let cleanupScope = remoteDataScopeKey(for: cleanupContext)
        if isCurrentRemoteScope(cleanupScope) {
            enqueueRTCTerminalCompensation(
                callID: callID,
                action: .hangup,
                reason: reason,
                context: cleanupContext
            )
        } else {
            // The server accepted this resource under the frozen old context before
            // the account/tenant changed. Perform one bounded cleanup with that exact
            // authority, but never retain it for retries in the new scope.
            do {
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                let idempotencyKey = makeRTCTerminalCompensationIdempotencyKey(action: .hangup)
                // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                try await api.hangupRTCCall(
                    context: cleanupContext,
                    callID: callID,
                    reason: reason,
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    idempotencyKey: idempotencyKey
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                )
            } catch {
                logSyncEndpointFailure("/api/rtc/calls/{id}/hangup", error: error)
            }
        }
        if directCallResourceOwners[callID] == attempt {
            directCallResourceOwners.removeValue(forKey: callID)
        }
        clearCurrentDirectCallAttempt(
            kind: attempt.kind,
            operationID: attempt.operationID
        )
    }

    func isCurrentDirectCallAttempt(_ attempt: DirectCallAttempt) -> Bool {
        guard !Task.isCancelled,
              currentDirectCallAttempt(for: attempt.kind) == attempt,
              directCallCapabilityGeneration(for: attempt.kind) == attempt.capabilityGeneration,
              DirectCallContextBinding(context: apiContext) == attempt.context else {
            return false
        }
        switch attempt.kind {
        case .voice:
            return isVoiceCallLicensedForCurrentTenant
        case .video:
            return attempt.mediaMode == "audio"
                ? isVoiceCallLicensedForCurrentTenant : isVideoCallLicensedForCurrentTenant
        }
    }

    private func ensureDirectCallAttemptIsCurrent(_ attempt: DirectCallAttempt) throws {
        guard isCurrentDirectCallAttempt(attempt) else {
            throw CancellationError()
        }
    }

    private func awaitDirectCallStage<Value>(
        _ attempt: DirectCallAttempt?,
        operation: () async throws -> Value
    ) async throws -> Value {
        if let attempt {
            try ensureDirectCallAttemptIsCurrent(attempt)
        }
        do {
            let value = try await operation()
            if let attempt {
                try ensureDirectCallAttemptIsCurrent(attempt)
            }
            return value
        } catch {
            if let attempt {
                try ensureDirectCallAttemptIsCurrent(attempt)
                _ = presentRTCLicenseFailure(error, media: attempt.mediaMode == "audio" ? .voice : .video)
            }
            throw error
        }
    }

    private func activeCallMatchesDirectCallAttempt(_ attempt: DirectCallAttempt) -> Bool {
        guard let activeCall = activeVoiceCall,
              activeCall.peer.id.trimmingCharacters(in: .whitespacesAndNewlines) == attempt.peerID,
              activeCall.isVideoCall == (attempt.kind == .video) else {
            return false
        }
        let activeMode = activeCall.mediaMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard activeMode == attempt.mediaMode else { return false }
        let activeCallID = activeCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return attempt.callID.isEmpty || attempt.callID == activeCallID
    }

    private func finishDirectCallAttemptSetup(_ attempt: DirectCallAttempt) {
        guard currentDirectCallAttempt(for: attempt.kind)?.operationID == attempt.operationID else {
            abandonDirectCallSetup(attempt)
            return
        }
        switch attempt.kind {
        case .voice:
            isStartingVoiceCall = false
        case .video:
            isStartingVideoCall = false
        }
        if !activeCallMatchesDirectCallAttempt(attempt) {
            abandonDirectCallSetup(attempt)
        }
    }

#if DEBUG
    var directCallTrackingCountsForTesting: (
        attempts: Int,
        resourceOwners: Int,
        cleanupObligations: Int
    ) {
        (
            directCallAttempts.count,
            directCallResourceOwners.count,
            directCallCleanupObligations.count
        )
    }
#endif

    private func directCallAttemptForActiveCall(_ call: VoiceCallSession) -> DirectCallAttempt? {
        let kind: DirectCallCapabilityKind = call.isVideoCall ? .video : .voice
        guard let attempt = currentDirectCallAttempt(for: kind),
              activeCallMatchesDirectCallAttempt(attempt) else {
            return nil
        }
        return attempt
    }

    func bindVoiceCallSystemIntegration() {
        voiceCallSystem.start()
        voiceCallSystemEventTask?.cancel()
        voiceCallSystemEventTask = Task { [weak self, voiceCallSystem] in
            for await event in voiceCallSystem.events {
                await MainActor.run {
                    self?.handleVoiceCallSystemEvent(event)
                }
            }
        }
    }

    func bindNotificationRuntime() {
        IOSNotificationRuntime.shared.removeObserver(notificationRuntimeObserverID)
        notificationRuntimeObserverID = IOSNotificationRuntime.shared.observe { [weak self] event in
            guard let self else { return false }
            self.handleNotificationRuntimeEvent(event)
            return true
        }
    }

    private func handleNotificationRuntimeEvent(_ event: IOSNotificationRuntimeEvent) {
        switch event {
        case .standardRegistrationChanged:
            resetStandardPushRegistrationKeys(for: apiContext)
            registerPendingStandardPushDeviceIfPossible(reason: "apns_token_changed")
        case let .standardRegistrationInvalidated(registration):
            resetStandardPushRegistrationKeys(for: apiContext)
            retireRegisteredPushTokenSlotIfPossible(
                provider: .apns,
                context: apiContext,
                fallbackRegistration: registration
            )
        case let .foregroundNotificationPresented(payload):
            toast = payload.title
        case let .notificationOpened(payload):
            handleOpenedNotification(payload)
        }
    }

    private func resetStandardPushRegistrationKeys(for context: IMAPIContext) {
        let scope = remoteDataScopeKey(for: context)
        registeredStandardPushDeviceRegistrationKeys = registeredStandardPushDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
    }

    private func handleOpenedNotification(_ payload: IOSNotificationStatePayload) {
        let context = apiContext
        guard context.hasIMSession else {
            if !deferredNotificationOpenPayloads.contains(payload) {
                deferredNotificationOpenPayloads.append(payload)
            }
            return
        }
        guard let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tenantID.isEmpty,
              payload.scopeKey == IOSNotificationRuntime.scopeKey(tenantID: tenantID) else {
            return
        }
        switch payload.category {
        case "voice_call", "video_call":
            guard !JHTRuntimeFeatureFlags.disableRTCRuntime else {
                activeTab = .chats
                return
            }
            activeTab = .rtc
            let scope = remoteDataScopeKey(for: context)
            Task { [weak self] in
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                await self?.refreshRTCSignalingSilently(context: context, scope: scope)
                // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            }
        default:
            activeTab = .chats
            let targetRef = payload.targetRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetRef.isEmpty else {
                // JHT_MOD_BEGIN NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改开始：缺少 target_ref 时按通知携带的 channel_id 打开会话
                guard let fallbackConversationID = notificationConversationID(fromOpenedMessagePayload: payload) else {
                    Task { [weak self] in
                        _ = await self?.refreshRemoteSnapshot(silent: true, force: true)
                    }
                    return
                }
                notificationTargetResolutionGeneration &+= 1
                let generation = notificationTargetResolutionGeneration
                let scope = remoteDataScopeKey(for: context)
                let authFence = context.authSessionFence
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence) else {
                        return
                    }
                    let conversationID = self.notificationConversationID(fromOpenedMessagePayload: payload) ?? fallbackConversationID
                    self.notificationConversationOpenRequest = IOSNotificationConversationOpenRequest(
                        conversationID: conversationID,
                        messageID: nil,
                        channelSeq: payload.channelSeq > 0 ? payload.channelSeq : nil
                    )
                }
                // JHT_MOD_END NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改结束
                return
            }
            notificationTargetResolutionGeneration &+= 1
            let generation = notificationTargetResolutionGeneration
            let scope = remoteDataScopeKey(for: context)
            let authFence = context.authSessionFence
            Task { [weak self] in
                guard let self else { return }
                do {
                    let target = try await api.resolveNotificationTarget(
                        context: context,
                        targetRef: targetRef
                    )
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence) else {
                        return
                    }
                    let conversationID: String
                    switch target.kind {
                    case .conversation:
                        conversationID = target.conversationID ?? ""
                        _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                    case .system:
                        conversationID = target.systemDestination ?? ""
                        await self.refreshInboxSilently()
                    }
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence),
                          !conversationID.isEmpty else {
                        return
                    }
                    self.notificationConversationOpenRequest = IOSNotificationConversationOpenRequest(
                        conversationID: conversationID,
                        messageID: target.messageID,
                        channelSeq: target.channelSeq
                    )
                } catch {
                    guard self.notificationTargetResolutionGeneration == generation,
                          self.isCurrentRemoteScope(scope),
                          self.apiContext.isSameAuthAuthority(as: authFence)
                            || self.apiContext.credentialsAdvanced(since: authFence) else {
                        return
                    }
                    _ = await self.refreshRemoteSnapshot(silent: true, force: true)
                }
            }
        }
    }

    // JHT_MOD_BEGIN NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改开始：通知点击兜底会话定位
    private func notificationConversationID(fromOpenedMessagePayload payload: IOSNotificationStatePayload) -> String? {
        let channelID = payload.channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else { return nil }
        if let conversation = conversations.first(where: { conversation in
            conversation.id == channelID
                || remoteChannelID(for: conversation).trimmingCharacters(in: .whitespacesAndNewlines) == channelID
        }) {
            return conversation.id
        }
        return channelID
    }
    // JHT_MOD_END NOTIFICATION_TAP_CHANNEL_FALLBACK_20260917 - 修改结束

    func consumeNotificationConversationOpenRequest(_ requestID: UUID) {
        guard notificationConversationOpenRequest?.id == requestID else { return }
        notificationConversationOpenRequest = nil
    }

    func replayDeferredNotificationOpensIfPossible() {
        guard apiContext.hasIMSession, !deferredNotificationOpenPayloads.isEmpty else { return }
        let pending = deferredNotificationOpenPayloads
        deferredNotificationOpenPayloads.removeAll()
        pending.forEach(handleOpenedNotification)
    }

    func retirePushDevices(for context: IMAPIContext) {
        guard context.hasIMSession else {
            clearPushRegistrationState()
            return
        }
        let scope = remoteDataScopeKey(for: context)
        registeredStandardPushDeviceIDsByScope.removeValue(forKey: scope)
        registeredVoIPPushDeviceIDsByScope.removeValue(forKey: scope)
        let standardFallback = registeredStandardPushRegistrationsByScope[scope]
            ?? IOSNotificationRuntime.shared.standardRegistration
        let voipFallback = registeredVoIPPushRegistrationsByScope[scope]
            ?? pendingVoIPDeviceRegistration
        registeredStandardPushDeviceRegistrationKeys = registeredStandardPushDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
        registeredVoIPDeviceRegistrationKeys = registeredVoIPDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
        let previousRetirement = pushDeviceRetirementTasksByScope[scope]
        let standardRegistration = standardPushRegistrationTasksByScope[scope]
        let voipRegistration = voipPushRegistrationTasksByScope[scope]
        let retirement = Task { [weak self] in
            await previousRetirement?.value
            await standardRegistration?.value
            await voipRegistration?.value
            guard let self else { return }
            self.registeredStandardPushDeviceIDsByScope.removeValue(forKey: scope)
            self.registeredVoIPPushDeviceIDsByScope.removeValue(forKey: scope)
            let standard = self.registeredStandardPushRegistrationsByScope.removeValue(forKey: scope)
                ?? standardFallback
            let voip = self.registeredVoIPPushRegistrationsByScope.removeValue(forKey: scope)
                ?? voipFallback
            if let fingerprint = standard?.tokenFingerprint {
                _ = try? await self.retirePushTokenWithTransientRetry(
                    context: context,
                    provider: .apns,
                    tokenFingerprint: fingerprint
                )
            }
            if let fingerprint = voip?.tokenFingerprint {
                _ = try? await self.retirePushTokenWithTransientRetry(
                    context: context,
                    provider: .apnsVoIP,
                    tokenFingerprint: fingerprint
                )
            }
        }
        pushDeviceRetirementTasksByScope[scope] = retirement
    }

    private func resetVoIPPushRegistrationKeys(for context: IMAPIContext) {
        let scope = remoteDataScopeKey(for: context)
        registeredVoIPDeviceRegistrationKeys = registeredVoIPDeviceRegistrationKeys.filter {
            !$0.hasPrefix("\(scope)|")
        }
    }

    func clearPushRegistrationState() {
        registeredStandardPushDeviceRegistrationKeys.removeAll()
        registeredVoIPDeviceRegistrationKeys.removeAll()
        registeredStandardPushDeviceIDsByScope.removeAll()
        registeredVoIPPushDeviceIDsByScope.removeAll()
        registeredStandardPushRegistrationsByScope.removeAll()
        registeredVoIPPushRegistrationsByScope.removeAll()
        deferredNotificationOpenPayloads.removeAll()
        IOSNotificationRuntime.shared.resetAuthenticatedScope()
        IOSNotificationRuntime.shared.updateApplicationBadge(0)
    }

    private func handleVoiceCallSystemEvent(_ event: VoiceCallSystemEvent) {
        switch event {
        case let .voipTokenUpdated(registration):
            if pendingVoIPDeviceRegistration != registration {
                resetVoIPPushRegistrationKeys(for: apiContext)
            }
            pendingVoIPDeviceRegistration = registration
            registerPendingVoIPDeviceIfPossible(reason: "voip_token")
        case .voipTokenInvalidated:
            let invalidatedRegistration = pendingVoIPDeviceRegistration
            pendingVoIPDeviceRegistration = nil
            resetVoIPPushRegistrationKeys(for: apiContext)
            retireRegisteredPushTokenSlotIfPossible(
                provider: .apnsVoIP,
                context: apiContext,
                fallbackRegistration: invalidatedRegistration
            )
        case let .voipPushPayload(payload):
            handleVoIPPushPayload(payload)
        case let .voipPushReportFailed(payload):
            voiceDebug("voip_push_callkit_report_failed call=\(Self.shortDebugID(payload.callID))")
            reconcileAuthoritativeRTCCallStateAfterVoIPPush()
        case let .voipPushContractViolation(payload):
            voiceDebug("voip_push_contract_violation event=\(payload.event) call=\(Self.shortDebugID(payload.callID))")
            reconcileAuthoritativeRTCCallStateAfterVoIPPush()
        case let .answer(callID):
            acceptVoiceCallFromSystem(callID: callID)
        case let .end(callID, reason):
            endVoiceCallFromSystem(callID: callID, reason: reason)
        case let .mute(callID, isMuted):
            setVoiceCallMutedFromSystem(callID: callID, isMuted: isMuted)
        case .audioSessionActivated:
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：保留系统音频激活顺序，辅助定位真机接听失败
            voiceCallSystemAudioSessionActive = true
            voiceCallSystemAudioSessionGeneration &+= 1
            voiceDebug("callkit_audio_session active=true gen=\(voiceCallSystemAudioSessionGeneration)")
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            renderCallPromptEnvironment(.callKitAudioSessionActivated)
            // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始：CallKit 交回音频会话后，恢复当前通话的 WebRTC 音频配置
            reconcileActiveCallAudioSession(reason: "callkit_audio_session_activated")
            // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束
        case .audioSessionDeactivated:
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            voiceCallSystemAudioSessionActive = false
            voiceCallSystemAudioSessionGeneration &+= 1
            voiceDebug("callkit_audio_session active=false gen=\(voiceCallSystemAudioSessionGeneration)")
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            renderCallPromptEnvironment(.callKitAudioSessionDeactivated)
        case .providerReset:
            renderCallPromptEnvironment(.mediaServicesReset)
            let lifecycleSnapshot = callStore.activeLifecycleSnapshot
            let visibleCallID = (activeVoiceCall?.callID ?? incomingVoiceCall?.callID ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentCallID = visibleCallID.isEmpty
                ? (lifecycleSnapshot?.identity.callID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : visibleCallID
            let hadTruthfulOwner = lifecycleSnapshot != nil
            let wasPendingIncoming = lifecycleSnapshot.map {
                $0.direction == .incoming && $0.phase == .ringing
            } ?? (incomingVoiceCall != nil && activeVoiceCall == nil)
            let wasUnconnectedOutgoing = lifecycleSnapshot?.direction == .outgoing
                && lifecycleSnapshot?.hasEverConnected != true
            let resetContext = apiContext
            let resetScope = remoteDataScopeKey(for: resetContext)
            if !currentCallID.isEmpty {
                rtcTerminalMarkersByCallID[currentCallID] = RTCCallTerminalMarker(
                    callID: currentCallID,
                    reason: "callkit_provider_reset",
                    stateVersion: max(0, lifecycleSnapshot?.revision ?? 0)
                )
            }
            _ = callStore.releaseLifecycle(as: .failure, reason: "callkit_provider_reset")
            SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
            SystemNotificationSound.stopAllCallPrompts()
            if !visibleCallID.isEmpty {
                finishVoiceCallFromRemote(
                    status: "连接失败",
                    subtitle: "语音通话 · 系统通话服务已重置",
                    toastText: "系统通话服务已重置，通话已结束",
                    endReason: "callkit_provider_reset",
                    stateVersion: max(0, lifecycleSnapshot?.revision ?? 0),
                    expectedCallID: currentCallID,
                    lifecyclePhase: .failure,
                    lifecycleAlreadyApplied: true
                )
            } else if hadTruthfulOwner {
                cancelVoiceCallWatchdog()
                stopRTCMediaStateHeartbeat(reason: "callkit_provider_reset")
                stopVoiceMediaSession(reason: "callkit_provider_reset")
                videoMediaEventTask?.cancel()
                videoMediaEventTask = nil
                activeVideoMediaCallID = nil
                if !currentCallID.isEmpty {
                    stoppedVideoMediaCallIDs.insert(currentCallID)
                    voiceCallSystem.endCall(callID: currentCallID, reason: "callkit_provider_reset")
                    voipPushPayloadsByCallID.removeValue(forKey: currentCallID)
                    rtcPeerWaitTerminationCallIDs.remove(currentCallID)
                    releaseDirectCallTracking(callID: currentCallID)
                }
                Task { [videoMediaClient] in
                    await videoMediaClient.stop(reason: "callkit_provider_reset")
                }
                activeVoiceCall = nil
                incomingVoiceCall = nil
                isEndingActiveCall = false
                activeCallEndError = nil
                releaseAudioSessionForVoiceCall()
                toast = "系统通话服务已重置，通话已结束"
            }
            guard !currentCallID.isEmpty, resetContext.hasIMSession else { return }
            guard isCurrentRemoteScope(resetScope) else { return }
            enqueueRTCTerminalCompensation(
                callID: currentCallID,
                action: wasPendingIncoming ? .reject : (wasUnconnectedOutgoing ? .cancel : .hangup),
                reason: "callkit_provider_reset",
                context: resetContext
            )
        }
    }

    private func handleVoIPPushPayload(_ payload: RTCVoIPPushPayload) {
        let callID = payload.callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty, payload.isPushKitEligibleRinging else {
            reconcileAuthoritativeRTCCallStateAfterVoIPPush()
            return
        }
        voipPushPayloadsByCallID[callID] = payload
        voiceDebug("voip_push event=ringing freshness=\(String(describing: payload.deliveryFreshness())) call=\(Self.shortDebugID(callID)) room=\(Self.shortDebugID(payload.roomID))")
        receiveIncomingVoiceCall(
            from: voiceCallPeer(from: payload),
            callID: callID,
            roomID: payload.roomID,
            mediaMode: payload.callType,
            systemOwnsRingtone: voiceCallSystem.hasPresentedCall(callID: callID)
        )
        reconcileAuthoritativeRTCCallStateAfterVoIPPush()
    }

    private func reconcileAuthoritativeRTCCallStateAfterVoIPPush() {
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        Task { [weak self] in
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            await self?.refreshRTCSignalingSilently(
                context: context,
                scope: scope,
                allowBackgroundExecution: true
            )
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        }
    }

    private func retireRegisteredPushTokenSlotIfPossible(
        provider: RemotePushTokenProvider,
        context: IMAPIContext,
        fallbackRegistration: RemoteDeviceRegistration? = nil
    ) {
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        let previousRetirement = pushDeviceRetirementTasksByScope[scope]
        let slotRegistrationTask = provider == .apns
            ? standardPushRegistrationTasksByScope[scope]
            : voipPushRegistrationTasksByScope[scope]
        let invalidatedRegistration: RemoteDeviceRegistration?
        if provider == .apns {
            invalidatedRegistration = fallbackRegistration
                ?? registeredStandardPushRegistrationsByScope[scope]
        } else {
            invalidatedRegistration = fallbackRegistration
                ?? registeredVoIPPushRegistrationsByScope[scope]
        }
        guard let invalidatedFingerprint = invalidatedRegistration?.tokenFingerprint else { return }
        let retirement = Task { [weak self] in
            await previousRetirement?.value
            await slotRegistrationTask?.value
            guard let self, self.isCurrentRemoteScope(scope) else { return }
            if provider == .apns {
                if self.registeredStandardPushRegistrationsByScope[scope]?.tokenFingerprint == invalidatedFingerprint {
                    self.registeredStandardPushRegistrationsByScope.removeValue(forKey: scope)
                    self.registeredStandardPushDeviceIDsByScope.removeValue(forKey: scope)
                }
            } else {
                if self.registeredVoIPPushRegistrationsByScope[scope]?.tokenFingerprint == invalidatedFingerprint {
                    self.registeredVoIPPushRegistrationsByScope.removeValue(forKey: scope)
                    self.registeredVoIPPushDeviceIDsByScope.removeValue(forKey: scope)
                }
            }
            _ = try? await self.retirePushTokenWithTransientRetry(
                context: context,
                provider: provider,
                tokenFingerprint: invalidatedFingerprint
            )
        }
        pushDeviceRetirementTasksByScope[scope] = retirement
    }

    private func retirePushTokenWithTransientRetry(
        context: IMAPIContext,
        provider: RemotePushTokenProvider,
        tokenFingerprint: String
    ) async throws -> RemotePushTokenRetirementResponse {
        do {
            return try await api.retireCurrentPushToken(
                context: context,
                provider: provider,
                tokenFingerprint: tokenFingerprint
            )
        } catch IMAPIError.httpStatus(let statusCode, _) where statusCode == 503 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return try await api.retireCurrentPushToken(
                context: context,
                provider: provider,
                tokenFingerprint: tokenFingerprint
            )
        }
    }

    func registerPendingVoIPDeviceIfPossible(reason: String) {
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: China-review build must not register VoIP/CallKit delivery.
        guard SystemCallIntegrationPolicy.isVoIPPushRegistrationEnabled else { return }
        // WDT_IOS1_CALLKIT_CN_POLICY_20260923_END
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        guard let registration = pendingVoIPDeviceRegistration else { return }
        let context = apiContext
        guard context.hasIMSession else {
            voiceDebug("voip_register_deferred reason=\(reason) context=\(Self.rtcDebugContextSummary(context))")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let key = "\(scope)|\(registration.deduplicationKey)"
        guard !registeredVoIPDeviceRegistrationKeys.contains(key) else { return }
        registeredVoIPDeviceRegistrationKeys.insert(key)
        let retirementTask = pushDeviceRetirementTasksByScope[scope]
        let previousRegistrationTask = voipPushRegistrationTasksByScope[scope]
        let registrationTask = Task { [weak self] in
            do {
                await retirementTask?.value
                await previousRegistrationTask?.value
                let device = try await self?.api.registerDevice(context: context, registration: registration)
                guard self?.isCurrentRemoteScope(scope) == true else {
                    if let fingerprint = registration.tokenFingerprint {
                        _ = try? await self?.api.retireCurrentPushToken(
                            context: context,
                            provider: .apnsVoIP,
                            tokenFingerprint: fingerprint
                        )
                    }
                    return
                }
                self?.registeredVoIPPushRegistrationsByScope[scope] = registration
                if let deviceID = device?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                   !deviceID.isEmpty {
                    self?.registeredVoIPPushDeviceIDsByScope[scope, default: []].insert(deviceID)
                }
                self?.voiceDebug("voip_register_ok environment=\(registration.environment ?? "empty") bundle=\(!((registration.bundleID ?? "").isEmpty))")
            } catch {
                await MainActor.run {
                    self?.registeredVoIPDeviceRegistrationKeys.remove(key)
                    self?.voiceDebug("voip_register_failed error=\(Self.safeVoiceErrorSummary(error))")
                }
            }
        }
        voipPushRegistrationTasksByScope[scope] = registrationTask
    }

    func registerPendingStandardPushDeviceIfPossible(reason _: String) {
        guard let registration = IOSNotificationRuntime.shared.standardRegistration else { return }
        let context = apiContext
        guard context.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: context)
        let key = "\(scope)|\(registration.deduplicationKey)"
        guard !registeredStandardPushDeviceRegistrationKeys.contains(key) else { return }
        registeredStandardPushDeviceRegistrationKeys.insert(key)
        let retirementTask = pushDeviceRetirementTasksByScope[scope]
        let previousRegistrationTask = standardPushRegistrationTasksByScope[scope]
        let registrationTask = Task { [weak self] in
            do {
                await retirementTask?.value
                await previousRegistrationTask?.value
                let device = try await self?.api.registerDevice(context: context, registration: registration)
                guard self?.isCurrentRemoteScope(scope) == true else {
                    if let fingerprint = registration.tokenFingerprint {
                        _ = try? await self?.api.retireCurrentPushToken(
                            context: context,
                            provider: .apns,
                            tokenFingerprint: fingerprint
                        )
                    }
                    return
                }
                self?.registeredStandardPushRegistrationsByScope[scope] = registration
                if let deviceID = device?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                   !deviceID.isEmpty {
                    self?.registeredStandardPushDeviceIDsByScope[scope, default: []].insert(deviceID)
                }
            } catch {
                _ = await MainActor.run {
                    self?.registeredStandardPushDeviceRegistrationKeys.remove(key)
                    #if DEBUG
                    print("[JHT Push] standard_register_failed error=\(IMAPIClient.redactedSensitiveLogText(String(describing: error)))")
                    #endif
                }
            }
        }
        standardPushRegistrationTasksByScope[scope] = registrationTask
    }

    private func voiceCallPeer(from payload: RTCVoIPPushPayload) -> IMUser {
        let caller = userForVoiceCall(uid: payload.callerUID)
        return voiceCallUser(
            merging: caller,
            uid: payload.callerProfile?.uid ?? payload.callerUID,
            userID: payload.callerProfile?.userID ?? "",
            displayName: payload.callerName,
            avatarURL: payload.callerAvatarURL,
            avatarVersion: payload.callerAvatarVersion,
            avatarUpdatedAt: payload.callerAvatarUpdatedAt
        )
    }

    private func acceptVoiceCallFromSystem(callID: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              !failedSystemAnsweredCallIDs.contains(normalizedCallID),
              rtcTerminalMarkersByCallID[normalizedCallID] == nil else { return }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: the app-requested action echoes through the system delegate.
        // Preserve the mode of this exact, still-authorized answer operation before
        // applying the system button's audio default. A different or invalidated
        // operation must continue through the normal ownership and license checks.
        if let operationID = callStore.incomingCallAnswerOperationID,
           incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID,
           directCallAttempts.values.contains(where: {
               $0.operationID == operationID && $0.callID == normalizedCallID
                   && $0.mediaMode == incomingCallAnswerMode && isCurrentDirectCallAttempt($0)
           }) {
            return
        }
        // WDT_IOS1_CALLKIT_ANSWER_20260921_END
        if incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedCallID,
           let payload = voipPushPayloadsByCallID[normalizedCallID] {
            let isVideo = payload.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
            incomingVoiceCall = IncomingVoiceCall(
                id: "incoming_\(UUID().uuidString)",
                callID: normalizedCallID,
                caller: voiceCallPeer(from: payload),
                startedAt: "刚刚",
                source: isVideo ? "系统视频来电" : "系统语音来电",
                requestedMediaMode: isVideo ? "video" : "audio"
            )
        }
        if !hasTruthfulCallOwnership {
            SystemNotificationSound.setSystemOwnsIncomingRingtone(true)
            _ = claimCallLifecycle(
                callID: normalizedCallID,
                direction: .incoming,
                reason: "callkit_answer_recovered_owner"
            )
        }
        if incomingVoiceCall?.isVideo == true {
            // A CallKit answer is explicit user intent, but the system UI cannot
            // choose camera mode. Start safely as audio; the in-app video answer
            // remains the only path that requests camera permission.
            acceptIncomingVideoCall(as: "audio", fromSystem: true)
        } else {
            acceptIncomingVoiceCall(fromSystem: true)
        }
    }

    private func endVoiceCallFromSystem(callID: String, reason: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        guard voiceCallSystem.hasPresentedCall(callID: normalizedCallID) else {
            voiceDebug(
                "system_end_skip reason=not_presented call=\(Self.shortDebugID(normalizedCallID)) event=\(reason)"
            )
            return
        }
        if activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            endActiveVoiceCall()
            return
        }
        if incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            declineIncomingVoiceCall()
            return
        }
        voiceCallSystem.clearPresentedCall(callID: normalizedCallID)
        guard apiContext.hasIMSession else { return }
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        Task { [weak self] in
            guard let self,
                  self.isCurrentRemoteScope(scope) else { return }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            let idempotencyKey = self.stableRTCTerminalMutationIdempotencyKey(
                callID: normalizedCallID,
                action: .reject,
                reason: reason,
                context: context
            )
            do {
                try await self.api.rejectRTCCall(
                    context: context,
                    callID: normalizedCallID,
                    idempotencyKey: idempotencyKey
                )
                self.clearRTCTerminalCompensationIfMatches(
                    callID: normalizedCallID,
                    action: .reject,
                    idempotencyKey: idempotencyKey
                )
            } catch {
                guard self.isCurrentRemoteScope(scope) else { return }
                self.enqueueRTCTerminalCompensationAfterInitialFailure(
                    callID: normalizedCallID,
                    action: .reject,
                    reason: reason,
                    context: context,
                    idempotencyKey: idempotencyKey,
                    error: error
                )
            }
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        }
    }

    private func setVoiceCallMutedFromSystem(callID: String, isMuted: Bool) {
        guard activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else { return }
        setActiveVoiceCallMuted(isMuted, notifySystem: false)
    }

    private func finishVoiceCallIfMatchingSystemCall(callID: String, event: String) {
        guard activeVoiceCall?.callID == callID || incomingVoiceCall?.callID == callID else { return }
        switch event {
        case "canceled":
            finishVoiceCallFromRemote(status: "已取消", subtitle: "语音通话 · 已取消", toastText: "语音通话已取消", expectedCallID: callID, lifecyclePhase: .cancelled)
        case "timed_out":
            finishVoiceCallFromRemote(status: "未接通", subtitle: "语音通话 · 已超时", toastText: "语音通话已超时", expectedCallID: callID, lifecyclePhase: .timeout)
        case "answered_elsewhere":
            finishVoiceCallFromRemote(status: "已在其他设备接听", subtitle: "语音通话 · 已在其他设备接听", toastText: "已在其他设备接听", expectedCallID: callID, lifecyclePhase: .ended)
        default:
            finishVoiceCallFromRemote(status: "已结束", subtitle: "语音通话 · 通话已结束", toastText: "语音通话已结束", expectedCallID: callID, lifecyclePhase: .ended)
        }
    }

    private func enqueueRTCTerminalCompensation(
        callID: String,
        action: RTCTerminalCompensationAction,
        reason: String,
        context: IMAPIContext? = nil,
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        idempotencyKey explicitIdempotencyKey: String? = nil,
        attemptCount initialAttemptCount: Int = 0,
        nextAttemptAtNanoseconds explicitNextAttemptAtNanoseconds: UInt64? = nil,
        lastErrorCode explicitLastErrorCode: String? = nil,
        retryImmediately: Bool = true
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundContext = directCallCleanupContext(context ?? apiContext)
        guard !normalizedCallID.isEmpty, boundContext.hasIMSession else { return }
        let scope = remoteDataScopeKey(for: boundContext)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        let now = rtcRequestNowNanoseconds()
        let existing = pendingRTCTerminalCompensations[normalizedCallID]
        let reuseExistingIntent = existing?.action == action
            && existing?.reason == reason
            && existing?.scope == scope
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        let explicitKey = explicitIdempotencyKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        let idempotencyKey = reuseExistingIntent
            ? existing?.idempotencyKey ?? makeRTCTerminalCompensationIdempotencyKey(action: action)
            : (explicitKey?.isEmpty == false ? explicitKey! : makeRTCTerminalCompensationIdempotencyKey(action: action))
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        let attemptCount = reuseExistingIntent
            ? max(existing?.attemptCount ?? 0, initialAttemptCount)
            : max(0, initialAttemptCount)
        let nextAttemptAtNanoseconds: UInt64
        if let explicitNextAttemptAtNanoseconds {
            nextAttemptAtNanoseconds = explicitNextAttemptAtNanoseconds
        } else if reuseExistingIntent {
            nextAttemptAtNanoseconds = existing?.nextAttemptAtNanoseconds ?? now
        } else {
            nextAttemptAtNanoseconds = now
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        pendingRTCTerminalCompensations[normalizedCallID] = PendingRTCTerminalCompensation(
            callID: normalizedCallID,
            action: action,
            reason: reason,
            context: boundContext,
            scope: scope,
            idempotencyKey: idempotencyKey,
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            attemptCount: attemptCount,
            nextAttemptAtNanoseconds: nextAttemptAtNanoseconds,
            lastErrorCode: explicitLastErrorCode ?? (reuseExistingIntent ? existing?.lastErrorCode : nil)
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        )
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        if retryImmediately {
            retryDuePendingRTCTerminalCompensations(reason: "enqueue")
        } else {
            scheduleNextRTCTerminalCompensationRetry()
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
    private func stableRTCTerminalMutationIdempotencyKey(
        callID: String,
        action: RTCTerminalCompensationAction,
        reason: String,
        context: IMAPIContext
    ) -> String {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = remoteDataScopeKey(for: context)
        if let existing = pendingRTCTerminalCompensations[normalizedCallID],
           existing.action == action,
           existing.reason == reason,
           existing.scope == scope {
            return existing.idempotencyKey
        }
        return makeRTCTerminalCompensationIdempotencyKey(action: action)
    }

    private func enqueueRTCTerminalCompensationAfterInitialFailure(
        callID: String,
        action: RTCTerminalCompensationAction,
        reason: String,
        context: IMAPIContext,
        idempotencyKey: String,
        error: Error
    ) {
        let lastErrorCode = RTCTerminalCompensationRetryPolicy.normalizedErrorCode(error)
        let decision = RTCTerminalCompensationRetryPolicy.decision(
            for: error,
            attemptCount: 1,
            stableKey: idempotencyKey,
            failureDelays: rtcTerminalCompensationFailureDelayNanoseconds,
            maximumAttempts: rtcTerminalCompensationMaximumAttempts
        )
        switch decision {
        case .satisfied:
            clearRTCTerminalCompensationIfMatches(
                callID: callID,
                action: action,
                idempotencyKey: idempotencyKey
            )
            clearLocalRTCTerminalCompensationFlags(callID: callID)
        case .pause:
            enqueueRTCTerminalCompensation(
                callID: callID,
                action: action,
                reason: reason,
                context: context,
                idempotencyKey: idempotencyKey,
                attemptCount: 1,
                nextAttemptAtNanoseconds: UInt64.max,
                lastErrorCode: lastErrorCode,
                retryImmediately: false
            )
        case .retry(let delay):
            enqueueRTCTerminalCompensation(
                callID: callID,
                action: action,
                reason: reason,
                context: context,
                idempotencyKey: idempotencyKey,
                attemptCount: 1,
                nextAttemptAtNanoseconds: RTCRequestBackoffPolicy.addingClamped(
                    rtcRequestNowNanoseconds(),
                    delay
                ),
                lastErrorCode: lastErrorCode,
                retryImmediately: false
            )
        }
    }

    private func clearRTCTerminalCompensationIfMatches(
        callID: String,
        action: RTCTerminalCompensationAction,
        idempotencyKey: String
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = pendingRTCTerminalCompensations[normalizedCallID],
              current.action == action,
              current.idempotencyKey == idempotencyKey else { return }
        pendingRTCTerminalCompensations.removeValue(forKey: normalizedCallID)
        clearLocalRTCTerminalCompensationFlags(callID: normalizedCallID)
        scheduleNextRTCTerminalCompensationRetry()
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911

    private func retryPendingRTCTerminalCompensations(callID: String? = nil) {
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        retryDuePendingRTCTerminalCompensations(callID: callID, reason: "compat")
    }

    private func retryDuePendingRTCTerminalCompensations(
        callID: String? = nil,
        reason: String
    ) {
        let now = rtcRequestNowNanoseconds()
        for key in pendingRTCTerminalCompensations.keys.sorted() {
            guard var intent = pendingRTCTerminalCompensations[key] else { continue }
            // Completion may consume a queued retry for this call only. A global
            // sweep here marks other in-flight calls again and creates a feedback loop.
            guard callID == nil || intent.callID == callID else { continue }
            guard isCurrentRemoteScope(intent.scope) else { continue }
            guard intent.attemptCount < rtcTerminalCompensationMaximumAttempts,
                  intent.nextAttemptAtNanoseconds <= now else { continue }
            guard rtcTerminalCompensationsInFlight.insert(intent.callID).inserted else {
                rtcTerminalCompensationRetryRequested.insert(intent.callID)
                continue
            }
            intent.attemptCount += 1
            pendingRTCTerminalCompensations[intent.callID] = intent
            let generation = rtcTerminalCompensationGeneration
            voiceDebug("terminal_compensation_retry reason=\(reason) call=\(Self.shortDebugID(intent.callID)) attempt=\(intent.attemptCount) action=\(intent.action)")
            Task { @MainActor [weak self, api, intent] in
                guard let self else { return }
                guard self.rtcTerminalCompensationGeneration == generation else { return }
                guard self.isCurrentRemoteScope(intent.scope) else {
                    self.rtcTerminalCompensationsInFlight.remove(intent.callID)
                    self.scheduleNextRTCTerminalCompensationRetry()
                    return
                }
                do {
                    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_BEGIN: a queued Task must not restore its stale captured token.
                    let retained = self.pendingRTCTerminalCompensations[intent.callID]
                    let latestOwnedContext: IMAPIContext
                    if let retained,
                       retained.action == intent.action,
                       retained.idempotencyKey == intent.idempotencyKey,
                       DirectCallContextBinding(context: retained.context) == DirectCallContextBinding(context: intent.context) {
                        latestOwnedContext = retained.context
                    } else {
                        latestOwnedContext = intent.context
                    }
                    let requestContext = self.directCallCleanupContext(latestOwnedContext)
                    // WDT_IOS1_CLEANUP_CREDENTIALS_20260921_END
                    if var current = self.pendingRTCTerminalCompensations[intent.callID],
                       current.action == intent.action,
                       current.idempotencyKey == intent.idempotencyKey {
                        current.context = requestContext
                        self.pendingRTCTerminalCompensations[intent.callID] = current
                    }
                    switch intent.action {
                    case .reject:
                        try await api.rejectRTCCall(
                            context: requestContext,
                            callID: intent.callID,
                            idempotencyKey: intent.idempotencyKey
                        )
                    case .cancel:
                        try await api.cancelRTCCall(
                            context: requestContext,
                            callID: intent.callID,
                            reason: intent.reason,
                            idempotencyKey: intent.idempotencyKey
                        )
                    case .hangup:
                        try await api.hangupRTCCall(
                            context: requestContext,
                            callID: intent.callID,
                            reason: intent.reason,
                            idempotencyKey: intent.idempotencyKey
                        )
                    }
                    guard self.rtcTerminalCompensationGeneration == generation else { return }
                    guard self.isCurrentRemoteScope(intent.scope) else {
                        self.rtcTerminalCompensationsInFlight.remove(intent.callID)
                        self.scheduleNextRTCTerminalCompensationRetry()
                        return
                    }
                    self.rtcTerminalCompensationsInFlight.remove(intent.callID)
                    self.rtcTerminalCompensationRetryRequested.remove(intent.callID)
                    if let current = self.pendingRTCTerminalCompensations[intent.callID],
                       current.action == intent.action,
                       current.idempotencyKey == intent.idempotencyKey {
                        self.pendingRTCTerminalCompensations.removeValue(forKey: intent.callID)
                    }
                    self.clearLocalRTCTerminalCompensationFlags(callID: intent.callID)
                    self.scheduleNextRTCTerminalCompensationRetry()
                } catch {
                    guard self.rtcTerminalCompensationGeneration == generation else { return }
                    guard self.isCurrentRemoteScope(intent.scope) else {
                        self.rtcTerminalCompensationsInFlight.remove(intent.callID)
                        self.scheduleNextRTCTerminalCompensationRetry()
                        return
                    }
                    self.rtcTerminalCompensationsInFlight.remove(intent.callID)
                    self.rtcTerminalCompensationRetryRequested.remove(intent.callID)
                    self.logSyncEndpointFailure("/api/rtc/calls/{id}/terminal", error: error)
                    guard var current = self.pendingRTCTerminalCompensations[intent.callID],
                          current.idempotencyKey == intent.idempotencyKey else {
                        self.scheduleNextRTCTerminalCompensationRetry()
                        return
                    }
                    current.lastErrorCode = RTCTerminalCompensationRetryPolicy.normalizedErrorCode(error)
                    let decision = RTCTerminalCompensationRetryPolicy.decision(
                        for: error,
                        attemptCount: current.attemptCount,
                        stableKey: current.idempotencyKey,
                        failureDelays: self.rtcTerminalCompensationFailureDelayNanoseconds,
                        maximumAttempts: self.rtcTerminalCompensationMaximumAttempts
                    )
                    switch decision {
                    case .satisfied:
                        self.pendingRTCTerminalCompensations.removeValue(forKey: intent.callID)
                        self.clearLocalRTCTerminalCompensationFlags(callID: intent.callID)
                        self.voiceDebug("terminal_compensation_satisfied_by_error call=\(Self.shortDebugID(intent.callID)) code=\(current.lastErrorCode ?? "unknown")")
                    case .pause:
                        current.nextAttemptAtNanoseconds = UInt64.max
                        self.pendingRTCTerminalCompensations[intent.callID] = current
                        self.voiceDebug("terminal_compensation_paused call=\(Self.shortDebugID(intent.callID)) attempt=\(current.attemptCount) code=\(current.lastErrorCode ?? "unknown")")
                    case .retry(let delay):
                        current.nextAttemptAtNanoseconds = RTCRequestBackoffPolicy.addingClamped(
                            self.rtcRequestNowNanoseconds(),
                            delay
                        )
                        self.pendingRTCTerminalCompensations[intent.callID] = current
                        self.voiceDebug("terminal_compensation_backoff call=\(Self.shortDebugID(intent.callID)) attempt=\(current.attemptCount) delay_ms=\(delay / 1_000_000) code=\(current.lastErrorCode ?? "unknown")")
                    }
                    self.scheduleNextRTCTerminalCompensationRetry()
                }
            }
        }
        scheduleNextRTCTerminalCompensationRetry()
    }

    private func scheduleNextRTCTerminalCompensationRetry() {
        rtcTerminalCompensationTimerTask?.cancel()
        rtcTerminalCompensationTimerTask = nil
        rtcTerminalCompensationTimerTaskID = nil

        let now = rtcRequestNowNanoseconds()
        let nextAttemptAt = pendingRTCTerminalCompensations.values
            .filter { intent in
                isCurrentRemoteScope(intent.scope)
                    && !rtcTerminalCompensationsInFlight.contains(intent.callID)
                    && intent.attemptCount < rtcTerminalCompensationMaximumAttempts
                    && intent.nextAttemptAtNanoseconds < UInt64.max
            }
            .map(\.nextAttemptAtNanoseconds)
            .min()
        guard let nextAttemptAt else { return }

        let delay = nextAttemptAt > now ? nextAttemptAt - now : 0
        let operationID = UUID()
        rtcTerminalCompensationTimerTaskID = operationID
        rtcTerminalCompensationTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await self.rtcRequestSleep(delay)
            }
            guard !Task.isCancelled,
                  self.rtcTerminalCompensationTimerTaskID == operationID else { return }
            self.rtcTerminalCompensationTimerTask = nil
            self.rtcTerminalCompensationTimerTaskID = nil
            self.retryDuePendingRTCTerminalCompensations(reason: "timer")
        }
    }

    private func clearLocalRTCTerminalCompensationFlags(callID: String) {
        busyRejectedIncomingCallIDs.remove(callID)
        failedSystemAnsweredCallIDs.remove(callID)
        coldLaunchUnsupportedCallIDs.remove(callID)
    }

    private func makeRTCTerminalCompensationIdempotencyKey(action: RTCTerminalCompensationAction) -> String {
        let actionName: String
        switch action {
        case .reject:
            actionName = "reject"
        case .cancel:
            actionName = "cancel"
        case .hangup:
            actionName = "hangup"
        }
        return "ios-\(actionName)-terminal-comp-\(UUID().uuidString.lowercased())"
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    func clearRTCTerminalCompensationsForScopeReset() {
        rtcTerminalCompensationGeneration &+= 1
        pendingRTCTerminalCompensations.removeAll()
        rtcTerminalCompensationsInFlight.removeAll()
        rtcTerminalCompensationRetryRequested.removeAll()
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        rtcTerminalCompensationTimerTask?.cancel()
        rtcTerminalCompensationTimerTask = nil
        rtcTerminalCompensationTimerTaskID = nil
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        busyRejectedIncomingCallIDs.removeAll()
        failedSystemAnsweredCallIDs.removeAll()
        coldLaunchUnsupportedCallIDs.removeAll()
    }

    private func rejectCompetingIncomingCallIfPossible(
        callID: String,
        reason: String = "client_busy"
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              busyRejectedIncomingCallIDs.insert(normalizedCallID).inserted else { return }
        voiceCallSystem.endCall(callID: normalizedCallID, reason: reason)
        rtcTerminalMarkersByCallID[normalizedCallID] = RTCCallTerminalMarker(
            callID: normalizedCallID,
            reason: reason,
            stateVersion: 0
        )
        voipPushPayloadsByCallID.removeValue(forKey: normalizedCallID)
        let context = apiContext
        guard context.hasIMSession else { return }
        enqueueRTCTerminalCompensation(
            callID: normalizedCallID,
            action: .reject,
            reason: reason,
            context: context
        )
    }

    private func rejectPresentedIncomingCallForAdmissionFailure(callID: String, reason: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        rejectCompetingIncomingCallIfPossible(callID: normalizedCallID, reason: reason)
    }

    private func rollbackFailedSystemAnswer(
        callID: String,
        context: IMAPIContext,
        reason: String,
        rejectServer: Bool,
        preservingEstablishedCall: Bool = false
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        if preservingEstablishedCall,
           let active = activeVoiceCall,
           active.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID,
           active.connectedAt != nil || active.mediaState == .connected || active.isRecoveringNetwork {
            return
        }
        guard !normalizedCallID.isEmpty,
              failedSystemAnsweredCallIDs.insert(normalizedCallID).inserted else { return }
        voiceCallSystem.endCall(callID: normalizedCallID, reason: reason)
        rtcTerminalMarkersByCallID[normalizedCallID] = RTCCallTerminalMarker(
            callID: normalizedCallID,
            reason: reason,
            stateVersion: 0
        )
        let ownsIncoming = incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID
        let ownsLifecycle = callStore.activeLifecycleSnapshot?.identity.callID == normalizedCallID
        if ownsIncoming {
            incomingVoiceCall = nil
        }
        if activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            activeVoiceCall = nil
        }
        if ownsLifecycle {
            _ = advanceCallLifecycle(callID: normalizedCallID, to: .failure, reason: reason)
            releaseCallLifecycle(as: .failure, reason: reason)
        }
        releaseDirectCallTracking(callID: normalizedCallID)
        voipPushPayloadsByCallID.removeValue(forKey: normalizedCallID)
        if ownsIncoming || ownsLifecycle {
            SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
            SystemNotificationSound.stopIncomingCallFallback()
        }
        guard rejectServer, context.hasIMSession else { return }
        enqueueRTCTerminalCompensation(
            callID: normalizedCallID,
            action: .reject,
            reason: reason,
            context: context
        )
    }

    func receiveIncomingVoiceCall(
        from caller: IMUser,
        callID: String? = nil,
        roomID: String? = nil,
        mediaMode: String = "audio",
        stateVersion: Int64 = 0,
        systemOwnsRingtone: Bool = false
    ) {
        discardUnownedLegacyCallViews(reason: "incoming_truth_reconcile")
        let normalizedCallID = callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        releaseAbandonedCallOwnershipBeforeIncoming(callID: normalizedCallID)
        voiceDebug("incoming_receive_attempt call=\(Self.shortDebugID(callID ?? "")) caller=\(Self.shortDebugID(caller.id)) room=\(Self.shortDebugID(roomID ?? "")) active=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) existing=\(Self.shortDebugID(incomingVoiceCall?.callID ?? ""))")
        if let reason = incomingVoiceCallUnavailableReason(for: caller) {
            voiceDebug("incoming_receive_reject reason=policy message=\(reason)")
            rejectPresentedIncomingCallForAdmissionFailure(callID: normalizedCallID, reason: "policy_unavailable")
            toast = reason
            return
        }
        let isVideo = mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
        if isVideo, (!fileUploadConfig.videoCallEnabled || !videoMediaClient.isAvailable) {
            rejectPresentedIncomingCallForAdmissionFailure(callID: normalizedCallID, reason: "video_unavailable")
            toast = fileUploadConfig.videoCallEnabled ? videoMediaClientUnavailableReason : "当前企业未开通视频通话"
            return
        }
        guard !normalizedCallID.isEmpty else {
            voiceDebug("incoming_receive_reject reason=empty_call_id")
            return
        }
        guard rtcTerminalMarkersByCallID[normalizedCallID] == nil else {
            voiceDebug("incoming_receive_reject reason=terminal_marker call=\(Self.shortDebugID(normalizedCallID))")
            if voiceCallSystem.hasPresentedCall(callID: normalizedCallID) {
                voiceCallSystem.endCall(callID: normalizedCallID, reason: "terminal_marker")
            }
            return
        }
        if isVideo { videoCallTerminalResult = nil }
        if let incomingVoiceCall {
            let existingCallID = incomingVoiceCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nextCallID = normalizedCallID
            if !existingCallID.isEmpty, existingCallID == nextCallID {
                voiceDebug("incoming_receive_existing call=\(Self.shortDebugID(existingCallID)) action=refresh_caller")
                if systemOwnsRingtone {
                    SystemNotificationSound.setSystemOwnsIncomingRingtone(true)
                }
                refreshIncomingVoiceCallCallerIfBetter(caller, matching: nextCallID)
                // A delayed higher-authority state event may be the first event
                // that carries the requested video type. Apply monotonic
                // refinements without ever downgrading an already-known video
                // call to audio.
                if stateVersion >= incomingVoiceCall.stateVersion {
                    self.incomingVoiceCall?.stateVersion = max(incomingVoiceCall.stateVersion, stateVersion)
                    if isVideo {
                        self.incomingVoiceCall?.requestedMediaMode = "video"
                        self.incomingVoiceCall?.source = "好友视频通话"
                    }
                }
                return
            }
            voiceDebug("incoming_receive_reject reason=existing_incoming existing=\(Self.shortDebugID(existingCallID)) next=\(Self.shortDebugID(nextCallID))")
            rejectCompetingIncomingCallIfPossible(callID: nextCallID)
            toast = "请先处理当前来电"
            return
        }
        guard !hasTruthfulCallOwnership else {
            voiceDebug("incoming_receive_reject reason=active_call active=\(Self.shortDebugID(activeVoiceCall?.callID ?? ""))")
            rejectCompetingIncomingCallIfPossible(callID: normalizedCallID)
            toast = "当前正在通话中"
            return
        }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(systemOwnsRingtone)
        guard claimCallLifecycle(
            callID: normalizedCallID,
            direction: .incoming,
            stateVersion: stateVersion,
            reason: "incoming_ringing"
        ) else { return }
        incomingVoiceCall = IncomingVoiceCall(
            id: "incoming_\(UUID().uuidString)",
            callID: callID,
            caller: caller,
            startedAt: "刚刚",
            source: isVideo ? "好友视频通话" : "好友语音通话"
            ,
            requestedMediaMode: isVideo ? "video" : "audio",
            stateVersion: stateVersion
        )
        voiceDebug("incoming_receive_set call=\(Self.shortDebugID(incomingVoiceCall?.callID ?? "")) caller=\(Self.shortDebugID(incomingVoiceCall?.caller.id ?? ""))")
        toast = "\(caller.name) 正在呼叫你"
    }

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: complete acceptIncomingVoiceCall implementation, including all failure cleanup branches.
    func acceptIncomingVoiceCall(fromSystem: Bool = false) {
        guard let call = incomingVoiceCall, !call.isVideo else { return }
        guard incomingCallAnswerMode == nil else { return }
        let systemCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // WDT_IOS1_CALLKIT_ANSWER_20260921: both app UI and system UI share CallKit audio ownership.
        let usesSystemAudio = fromSystem || voiceCallSystem.hasPresentedCall(callID: systemCallID)
        guard guardCallLicenseForAction(.voice) else {
            if usesSystemAudio {
                rollbackFailedSystemAnswer(callID: systemCallID, context: apiContext,
                    reason: "callkit_answer_license_unavailable", rejectServer: true,
                    preservingEstablishedCall: true)
            }
            return
        }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            if usesSystemAudio {
                rollbackFailedSystemAnswer(
                    callID: systemCallID,
                    context: context,
                    reason: "callkit_answer_session_unavailable",
                    rejectServer: false
                )
            }
            return
        }
        let scope = remoteDataScopeKey(for: context)
        var attempt = beginDirectCallAttempt(
            kind: .voice,
            context: context,
            callID: call.callID ?? "",
            peerID: call.caller.id,
            mediaMode: "audio"
        )
        guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
        callStore.incomingCallAnswerOperationID = attempt.operationID
        incomingCallAnswerMode = "audio"
        Task {
            defer {
                if callStore.incomingCallAnswerOperationID == attempt.operationID {
                    callStore.incomingCallAnswerOperationID = nil
                    incomingCallAnswerMode = nil
                }
                finishDirectCallAttemptSetup(attempt)
            }
            var acceptedCallID: String?
            var acceptedCallContext = context
            var installedActiveCall = false
            do {
                try await ensureRTCProviderReadyForAudioCall(
                    context: context,
                    scope: scope,
                    attempt: attempt
                )
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
                let microphoneAuthorized = try await awaitDirectCallStage(attempt) {
                    await ensureMicrophonePermissionForVoiceCall()
                }
                guard microphoneAuthorized else {
                    if usesSystemAudio {
                        rollbackFailedSystemAnswer(
                            callID: systemCallID,
                            context: context,
                            reason: "callkit_answer_microphone_denied",
                            rejectServer: true
                        )
                    }
                    return
                }
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: answer the already-presented system call before media setup.
                if usesSystemAudio && !fromSystem {
                    try await awaitDirectCallStage(attempt) {
                        try await voiceCallSystem.answerPresentedCall(callID: systemCallID)
                    }
                }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_END
                try configureAudioSessionForVoiceCall()
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else {
                    releaseAudioSessionForVoiceCall()
                    return
                }
                let response: RemoteRTCCallResponse?
                if let callID = call.callID, !callID.isEmpty {
                    response = try await awaitDirectCallStage(attempt) {
                        let requestContext = try currentDirectCallRequestContext(context, attempt: attempt)
                        acceptedCallContext = requestContext
                        return try await api.acceptRTCCall(context: requestContext, callID: callID)
                    }
                    acceptedCallID = response?.call.id.isEmpty == false ? response?.call.id : callID
                    attempt = try rebindDirectCallAttempt(
                        attempt,
                        callID: acceptedCallID
                    )
                    if let acceptedCallID {
                        registerAcceptedDirectCallCleanupObligation(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            attempt: attempt
                        )
                    }
                } else {
                    response = nil
                }
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else {
                    releaseAudioSessionForVoiceCall()
                    if let acceptedCallID, !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                var joinedRoom: RemoteRTCRoomJoinData?
                var acceptedRemoteCall: RemoteRTCCall?
                if let response {
                    guard !response.call.roomID.isEmpty,
                          !response.rtcToken.isEmpty else {
                        throw IMAPIError.server("语音房间信息不完整")
                    }
                    joinedRoom = try await awaitDirectCallStage(attempt) {
                        try await api.joinRTCRoom(
                            context: currentDirectCallRequestContext(acceptedCallContext, attempt: attempt),
                            roomID: response.call.roomID,
                            rtcToken: response.rtcToken
                        )
                    }
                    acceptedRemoteCall = rtcCall(response.call, withRTCToken: response.rtcToken)
                }
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else {
                    releaseAudioSessionForVoiceCall()
                    if let acceptedCallID, !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                let lifecycleCallID = acceptedRemoteCall?.id.isEmpty == false
                    ? acceptedRemoteCall!.id
                    : (call.callID ?? "")
                _ = advanceCallLifecycle(
                    callID: lifecycleCallID,
                    to: .dialing,
                    stateVersion: (acceptedRemoteCall?.stateVersion ?? 0) > 0 ? acceptedRemoteCall?.stateVersion : nil,
                    reason: "incoming_answered_media_connecting"
                )
                activeVoiceCall = VoiceCallSession(
                    id: "call_\(UUID().uuidString)",
                    callID: acceptedRemoteCall?.id.isEmpty == false ? acceptedRemoteCall?.id : call.callID,
                    roomID: acceptedRemoteCall?.roomID ?? "",
                    rtcToken: response?.rtcToken ?? "",
                    mediaBaseURL: joinedRoom?.media.owtBaseURL ?? "",
                    peer: call.caller,
                    direction: "来电",
                    startedAt: call.startedAt,
                    statusText: "连接中",
                    mediaState: .preparing,
                    isMuted: false,
                    speakerOn: true,
                    startedAtDate: Date(),
                    connectedAt: nil
                )
                installedActiveCall = true
                incomingVoiceCall = nil
                toast = nil
                if let acceptedRemoteCall, let joinedRoom {
                    let readyRoom = try await joinedRoomReadyForVoiceStart(
                        call: acceptedRemoteCall,
                        joinedRoom: joinedRoom,
                        context: acceptedCallContext,
                        roomID: acceptedRemoteCall.roomID,
                        rtcToken: response?.rtcToken ?? acceptedRemoteCall.rtcToken,
                        scope: scope,
                        attempt: attempt
                    )
                    guard isCurrentDirectCallAttempt(attempt),
                          directCallResourceIsOwned(callID: acceptedRemoteCall.id, by: attempt),
                          activeVoiceCall?.callID == acceptedRemoteCall.id else {
                        clearActiveDirectCallResourceIfOwned(
                            callID: acceptedRemoteCall.id,
                            by: attempt,
                            reason: "incoming_voice_scope_changed"
                        )
                        if let acceptedCallID, !acceptedCallID.isEmpty {
                            await hangupDirectCallResourceIfOwned(
                                context: acceptedCallContext,
                                callID: acceptedCallID,
                                by: attempt,
                                reason: "client_scope_changed"
                            )
                        }
                        return
                    }
                    if usesSystemAudio {
                        try await waitForCallKitAudioSessionBeforeVoiceStart(
                            callID: acceptedRemoteCall.id,
                            scope: scope,
                            attempt: attempt
                        )
                    }
                    startVoiceMediaSession(
                        call: acceptedRemoteCall,
                        joinedRoom: readyRoom,
                        direction: "来电",
                        peer: call.caller,
                        scope: scope,
                        attempt: attempt
                    )
                }
                resolveDirectCallCleanupObligations(for: attempt)
            } catch {
                if isCurrentDirectCallAttempt(attempt) || acceptedCallID.map({ directCallResourceIsOwned(callID: $0, by: attempt) }) == true {
                    releaseAudioSessionForVoiceCall()
                }
                if let waitError = error as? RTCPeerParticipantWaitError {
                    if waitError == .timedOut,
                       isCurrentDirectCallAttempt(attempt) {
                        if usesSystemAudio {
                            rollbackFailedSystemAnswer(
                                callID: acceptedCallID ?? systemCallID,
                                context: context,
                                reason: "callkit_answer_peer_timeout",
                                rejectServer: acceptedCallID == nil
                            )
                        }
                        return
                    }
                }
                guard isCurrentDirectCallAttempt(attempt) else {
                    if usesSystemAudio, acceptedCallID == nil {
                        rollbackUnconnectedSystemAnswerIfOwned(attempt: attempt, context: context)
                    }
                    if let acceptedCallID {
                        clearActiveDirectCallResourceIfOwned(
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "incoming_voice_scope_changed"
                        )
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                if installedActiveCall {
                    guard let acceptedCallID,
                          directCallResourceIsOwned(callID: acceptedCallID, by: attempt),
                          activeVoiceCall?.callID == acceptedCallID else { return }
                } else {
                    guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
                }
                let failedLifecycleCallID = acceptedCallID ?? call.callID ?? ""
                _ = advanceCallLifecycle(
                    callID: failedLifecycleCallID,
                    to: .failure,
                    reason: "incoming_voice_setup_failed"
                )
                activeVoiceCall = nil
                incomingVoiceCall = nil
                if let acceptedCallID, !acceptedCallID.isEmpty {
                    let failureReason = rtcCallFailureReason(
                        for: error,
                        defaultReason: "network_error"
                    )
                    Task {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: failureReason
                        )
                    }
                }
                if usesSystemAudio {
                    rollbackFailedSystemAnswer(
                        callID: acceptedCallID ?? systemCallID,
                        context: context,
                        reason: "callkit_answer_setup_failed",
                        rejectServer: acceptedCallID == nil
                    )
                }
                handleRemoteError(error, fallback: "接听通话失败", rtcMedia: .voice)
            }
        }
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END: complete acceptIncomingVoiceCall implementation.

    private func isCurrentIncomingVoiceAnswer(
        _ expected: IncomingVoiceCall,
        attempt: DirectCallAttempt
    ) -> Bool {
        guard attempt.kind == .voice,
              isCurrentDirectCallAttempt(attempt),
              let current = incomingVoiceCall,
              !current.isVideo,
              current.id == expected.id,
              current.caller.id == attempt.peerID else {
            return false
        }
        let expectedCallID = expected.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentCallID = current.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return currentCallID == expectedCallID
            && currentCallID == attempt.callID
    }

    private func rollbackUnconnectedSystemAnswerIfOwned(
        attempt: DirectCallAttempt,
        context: IMAPIContext
    ) {
        // Capability refresh may invalidate the attempt before its catch runs.
        // The UI may already be cleared by a successful license revocation.
        // Resource ownership survives capability invalidation, but is released
        // by explicit cancellation and replaced by a newer answer operation.
        guard DirectCallContextBinding(context: apiContext) == attempt.context,
              directCallResourceIsOwned(callID: attempt.callID, by: attempt) else { return }
        rollbackFailedSystemAnswer(
            callID: attempt.callID, context: context,
            reason: "callkit_answer_capability_changed", rejectServer: true,
            preservingEstablishedCall: true
        )
    }

    func declineIncomingVoiceCall() {
        guard let call = incomingVoiceCall else { return }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        let normalizedCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedCallID.isEmpty {
            let context = apiContext
            if context.hasIMSession {
                enqueueRTCTerminalCompensation(
                    callID: normalizedCallID,
                    action: .reject,
                    reason: "local_reject",
                    context: context
                )
            }
            voiceCallSystem.endCall(callID: normalizedCallID, reason: "local_reject")
            voipPushPayloadsByCallID.removeValue(forKey: normalizedCallID)
            releaseDirectCallTracking(callID: normalizedCallID)
        }
        let now = Date()
        let callKind = call.isVideo ? "视频" : "语音"
        calls.insert(
            CallRecord(
                id: "call_record_\(UUID().uuidString)",
                callID: call.callID,
                peerID: call.caller.id,
                peerUserID: call.caller.userID,
                peerAvatarURL: call.caller.avatarURL,
                peerAvatarVersion: call.caller.avatarVersion,
                peerAvatarUpdatedAt: call.caller.avatarUpdatedAt,
                peerAvatarSource: voiceCallAvatarSource(for: call.caller),
                title: call.caller.name,
                subtitle: "\(callKind)来电 · 我已拒接",
                time: displayTime(now),
                status: "已拒接",
                direction: .incoming,
                callType: "\(callKind)通话",
                startedAt: now,
                endedAt: now,
                durationSeconds: 0
            ),
            at: 0
        )
        _ = advanceCallLifecycle(
            callID: normalizedCallID,
            to: .rejected,
            reason: "local_reject"
        )
        incomingVoiceCall = nil
        toast = "已拒接\(callKind)通话"
    }

    private var localVideoCapabilities: RTCDeviceCapabilities {
        RTCDeviceCapabilities(
            version: RTCDeviceCapabilities.protocolVersion,
            audio: true,
            video: videoMediaClient.isAvailable,
            cameraAvailable: videoMediaClient.cameraAvailable,
        )
    }

    private static func normalizedRTCMediaMode(_ rawValue: String, fallback: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "video" || normalized == "audio" {
            return normalized
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" ? "video" : "audio"
    }

    private func rtcDeviceCapabilityReportSessionKey(for context: IMAPIContext) -> String? {
        guard context.hasIMSession else { return nil }
        let sessionDiscriminator = context.tenantAuthSession?.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDiscriminator = context.imToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedDiscriminator = sessionDiscriminator?.isEmpty == false
            ? sessionDiscriminator!
            : fallbackDiscriminator
        guard !resolvedDiscriminator.isEmpty else { return nil }
        return [
            remoteDataScopeKey(for: context),
            context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
            String(resolvedDiscriminator.hashValue)
        ].joined(separator: "|")
    }

    func resetRTCDeviceCapabilityReportState() {
        rtcDeviceCapabilitiesReportedSessionKey = nil
        rtcDeviceCapabilitiesReportInFlightKeys.removeAll()
    }

    func scheduleRTCDeviceCapabilitiesReportIfNeeded() {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        let context = apiContext
        guard isAuthenticated,
              context.hasIMSession,
              fileUploadConfig.videoCallEnabled,
              let sessionKey = rtcDeviceCapabilityReportSessionKey(for: context),
              rtcDeviceCapabilitiesReportedSessionKey != sessionKey,
              !rtcDeviceCapabilitiesReportInFlightKeys.contains(sessionKey) else {
            return
        }
        let capabilities = localVideoCapabilities
        rtcDeviceCapabilitiesReportInFlightKeys.insert(sessionKey)
        Task { [weak self, api, context, sessionKey, capabilities] in
            defer {
                self?.rtcDeviceCapabilitiesReportInFlightKeys.remove(sessionKey)
            }
            do {
                try await api.updateRTCDeviceCapabilities(context: context, capabilities: capabilities)
                guard let self,
                      self.isAuthenticated,
                      self.rtcDeviceCapabilityReportSessionKey(for: self.apiContext) == sessionKey else {
                    return
                }
                self.rtcDeviceCapabilitiesReportedSessionKey = sessionKey
            } catch {
                // Capability presence only optimizes reachability checks. Login and chat must stay available.
            }
        }
    }

    func presentVideoCallPreview(to peer: IMUser, channelID: String? = nil) {
        guard guardCallLicenseForAction(.video) else { return }
        guard !hasTruthfulCallOwnership else {
            toast = "请先处理当前通话"
            return
        }
        if let reason = videoCallUnavailableReason(for: peer) {
            toast = reason
            return
        }
        videoCallTerminalResult = nil
        let previewID = "video-preview-\(UUID().uuidString)"
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        let capabilityGeneration = callLicenseActionGeneration(for: .video)
        let binding = DirectCallContextBinding(context: context)
        if let previousID = videoCallPreview?.id {
            queueVideoPreviewCleanup(id: previousID, reason: "preview_replaced")
        }
        videoCallPreview = VideoCallPreview(
            id: previewID,
            peer: peer,
            channelID: channelID,
            cameraEnabled: videoMediaClient.cameraAvailable,
            isPreparing: true,
            unavailableReason: videoMediaClient.cameraAvailable ? nil : "未检测到摄像头，将以关闭摄像头方式呼叫"
        )
        Task { [weak self, videoMediaClient] in
            guard let self else { return }
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled
                    && self.isCurrentVideoCallPreview(id: previewID, peerID: peer.id, scope: scope)
                    && DirectCallContextBinding(context: self.apiContext) == binding
                    && self.callLicenseActionGeneration(for: .video) == capabilityGeneration
                    && !self.hasTruthfulCallOwnership
            }
            defer {
                if !isCurrent(), self.videoCallPreview?.id == previewID {
                    self.videoCallPreview = nil
                    self.queueVideoPreviewCleanup(id: previewID, reason: "preview_stale")
                }
            }
            guard isCurrent() else { return }
            do {
                _ = try await self.currentFileUploadConfig(
                    context: try self.currentDirectCallRequestContext(context),
                    scope: scope
                )
                guard isCurrent() else { return }
                let provider = try await self.currentRTCProvider(
                    context: try self.currentDirectCallRequestContext(context),
                    media: .video,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }
                try self.requireVideoProviderCapabilities(provider)
            } catch {
                guard isCurrent() else { return }
                self.videoCallPreview = nil
                self.queueVideoPreviewCleanup(id: previewID, reason: "preview_provider_unavailable")
                self.handleRemoteError(error, fallback: "视频通话服务暂不可用", rtcMedia: .video)
                return
            }
            guard isCurrent() else { return }
            let cameraGranted = await self.ensureVideoPermission()
            guard isCurrent() else { return }
            if cameraGranted {
                // Serialize only capture/cleanup, not permission prompts. A new
                // preview or call must never race an older preview's stop.
                let predecessor = self.videoPreviewMediaTask
                let preparation = Task { @MainActor [weak self, videoMediaClient] in
                    await predecessor?.value
                    guard let self, isCurrent() else { return }
                    if let previousOwner = self.videoPreviewMediaOwnerID, previousOwner != previewID {
                        await self.stopVideoPreviewMediaIfOwned(id: previousOwner, reason: "preview_replaced")
                    }
                    guard isCurrent() else { return }
                    self.videoPreviewMediaOwnerID = previewID
                    do {
                        try await videoMediaClient.preparePreview(preferFrontCamera: true)
                        guard isCurrent() else {
                            await self.stopVideoPreviewMediaIfOwned(id: previewID, reason: "preview_stale")
                            return
                        }
                        self.videoCallPreview?.cameraEnabled = true
                    } catch {
                        if isCurrent() {
                            self.videoCallPreview?.cameraEnabled = false
                            self.videoCallPreview?.unavailableReason = "摄像头暂不可用，可关闭摄像头继续"
                        }
                        await self.stopVideoPreviewMediaIfOwned(id: previewID, reason: "preview_prepare_failed")
                    }
                }
                self.videoPreviewMediaTask = preparation
                await preparation.value
                guard isCurrent() else { return }
            } else {
                self.videoCallPreview?.cameraEnabled = false
                self.videoCallPreview?.unavailableReason = "未开启摄像头权限，可关闭摄像头继续"
            }
            if isCurrent() {
                self.videoCallPreview?.isPreparing = false
            }
        }
    }

    private func isCurrentVideoCallPreview(
        id: String,
        peerID: String,
        scope: String
    ) -> Bool {
        isVideoCallLicensedForCurrentTenant
            && isCurrentRemoteScope(scope)
            && videoCallPreview?.id == id
            && videoCallPreview?.peer.id == peerID
    }

    private func stopVideoPreviewMediaIfOwned(id: String, reason: String) async {
        guard videoPreviewMediaOwnerID == id, activeVideoMediaCallID == nil else { return }
        await videoMediaClient.stop(reason: reason)
        if videoPreviewMediaOwnerID == id { videoPreviewMediaOwnerID = nil }
    }

    private func queueVideoPreviewCleanup(id: String, reason: String) {
        let predecessor = videoPreviewMediaTask
        videoPreviewMediaTask = Task { @MainActor [weak self] in
            await predecessor?.value
            await self?.stopVideoPreviewMediaIfOwned(id: id, reason: reason)
        }
    }

    func clearPendingVideoCallForLicenseRevocation() {
        let hadPendingVideoStart = videoCallPreview != nil
            || callStore.videoCallStartGeneration != nil
            || isStartingVideoCall
        guard hadPendingVideoStart else { return }
        let previewID = videoCallPreview?.id
        let peer = videoCallPreview?.peer
        callStore.videoCallStartGeneration = nil
        isStartingVideoCall = false
        videoCallPreview = nil
        if let peer {
            presentVideoCallTerminal(peer: peer, reason: "license_revoked", fallback: "视频通话不可用")
        }
        if let previewID {
            queueVideoPreviewCleanup(id: previewID, reason: "video_license_revoked")
        }
    }

    func dismissVideoCallPreview() {
        let previewID = videoCallPreview?.id
        if callStore.videoCallStartGeneration != nil {
            callStore.videoCallStartGeneration = nil
            isStartingVideoCall = false
        }
        videoCallPreview = nil
        if let previewID { queueVideoPreviewCleanup(id: previewID, reason: "preview_cancelled") }
    }

    func setVideoPreviewCameraEnabled(_ enabled: Bool) {
        guard !enabled || guardCallLicenseForAction(.video) else { return }
        guard videoCallPreview?.isStartingCall != true else { return }
        videoCallPreview?.cameraEnabled = enabled
        let generation = callLicenseActionGeneration(for: .video)
        Task { [weak self, videoMediaClient] in
            guard let self, self.callLicenseActionGeneration(for: .video) == generation,
                  !enabled || self.guardCallLicenseForAction(.video) else { return }
            try? await videoMediaClient.setCameraEnabled(enabled)
        }
    }

    func startOutgoingVideoCallFromPreview() {
        guard let preview = videoCallPreview else { return }
        guard !preview.isPreparing else { return }
        startOutgoingVideoCall(
            to: preview.peer,
            channelID: preview.channelID,
            cameraEnabled: preview.cameraEnabled,
            previewID: preview.id
        )
    }

    // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：识别并清理聊天页直发视频的轻量占位会话
    private func pendingOutgoingVideoCallPresentation(for attempt: DirectCallAttempt) -> VoiceCallSession? {
        guard attempt.kind == .video,
              let call = activeVoiceCall,
              call.direction == "呼出",
              call.isVideoCall,
              normalizedDirectCallID(call.callID ?? "").isEmpty,
              call.peer.id.trimmingCharacters(in: .whitespacesAndNewlines) == attempt.peerID,
              call.mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == attempt.mediaMode else {
            return nil
        }
        return call
    }

    private func clearPendingOutgoingVideoCallPresentation(for attempt: DirectCallAttempt) {
        guard pendingOutgoingVideoCallPresentation(for: attempt) != nil else { return }
        activeVoiceCall = nil
    }
    // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束

    func startOutgoingVideoCall(
        to target: IMUser,
        channelID: String? = nil,
        cameraEnabled: Bool = true,
        previewID: String? = nil,
        // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：仅聊天页直发视频使用，避免把网络/权限等待压在聊天页
        presentImmediately: Bool = false
        // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
    ) {
        guard guardCallLicenseForAction(.video) else { return }
        discardUnownedLegacyCallViews(reason: "outgoing_video_truth_reconcile")
        guard !isStartingVideoCall, !hasTruthfulCallOwnership else {
            if let previewID,
               videoCallPreview?.id == previewID,
               isStartingVideoCall {
                videoCallPreview?.isStartingCall = true
                videoCallPreview?.startError = nil
            } else {
                toast = "请先处理当前通话"
            }
            return
        }
        if let reason = videoCallUnavailableReason(for: target) {
            if let previewID, videoCallPreview?.id == previewID {
                videoCallPreview?.startError = reason
            } else {
                toast = reason
            }
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            if let previewID, videoCallPreview?.id == previewID {
                videoCallPreview?.startError = "登录会话不可用，请重新登录"
            } else {
                toast = "登录会话不可用，请重新登录"
            }
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let startedAt = Date()
        let generation = UUID()
        var attempt = beginDirectCallAttempt(
            kind: .video,
            context: context,
            peerID: target.id,
            mediaMode: "video"
        )
        callStore.videoCallStartGeneration = generation
        isStartingVideoCall = true
        if let previewID, videoCallPreview?.id == previewID {
            videoCallPreview?.isStartingCall = true
            videoCallPreview?.startError = nil
        }
        // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：聊天页直接点视频时先展示轻量通话页，真实 callID 回来后再补齐权威会话数据
        if presentImmediately, previewID == nil {
            activeVoiceCall = VoiceCallSession(
                id: "video-call-\(UUID().uuidString)",
                callID: nil,
                roomID: "",
                rtcToken: "",
                mediaBaseURL: "",
                peer: target,
                direction: "呼出",
                startedAt: "刚刚",
                statusText: "正在发起视频通话",
                mediaState: .preparing,
                isMuted: false,
                speakerOn: true,
                startedAtDate: startedAt,
                connectedAt: nil,
                requestedMediaMode: "video",
                mediaMode: "video",
                localCameraEnabled: false,
                stateVersion: 0,
                requiresAcceptedDeviceBeforeJoin: false
            )
        }
        // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
        Task {
            defer {
                finishVideoCallStartAttempt(generation: generation, previewID: previewID)
                finishDirectCallAttemptSetup(attempt)
            }
            var createdCallID = ""
            var createdCallContext = context
            do {
                let provider = try await ensureRTCProviderReadyForVideoCall(
                    context: context,
                    scope: scope,
                    attempt: attempt
                )
                try await awaitDirectCallStage(attempt) {
                    try await api.updateRTCDeviceCapabilities(
                        context: currentDirectCallRequestContext(context, attempt: attempt),
                        capabilities: localVideoCapabilities
                    )
                }
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let microphoneAuthorized = try await awaitDirectCallStage(attempt) {
                    await ensureMicrophonePermissionForVoiceCall()
                }
                guard microphoneAuthorized else {
                    throw IMAPIError.server("麦克风权限未开启，请在系统设置中允许 问达通 使用麦克风")
                }
                let cameraAvailable = videoMediaClient.cameraAvailable
                let cameraAuthorized = cameraEnabled && cameraAvailable
                    ? try await awaitDirectCallStage(attempt) {
                        await ensureVideoPermission()
                    }
                    : false
                let effectiveCameraEnabled = cameraEnabled && cameraAvailable && cameraAuthorized
                if RTCCallRecordRedialFreshnessContext.requiredCallType == .video,
                   !effectiveCameraEnabled {
                    throw IMAPIError.server("摄像头不可用，未发起视频通话")
                }
                if cameraEnabled, !effectiveCameraEnabled {
                    toast = cameraAvailable
                        ? "未开启摄像头权限，已关闭摄像头继续视频通话"
                        : "摄像头暂不可用，已关闭摄像头继续视频通话"
                }
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let response = try await awaitDirectCallStage(attempt) {
                    let requestContext = try currentDirectCallRequestContext(context, attempt: attempt)
                    createdCallContext = requestContext
                    return try await api.createRTCVideoCall(
                        context: requestContext,
                        calleeUID: target.id,
                        channelID: voiceCallChannelID(for: target, requestedChannelID: channelID),
                        capabilities: localVideoCapabilities
                    )
                }
                createdCallID = response.call.id
                attempt = try rebindDirectCallAttempt(
                    attempt,
                    callID: response.call.id
                )
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let joined = try await initialOutgoingRoomJoin(
                    response: response, context: createdCallContext, attempt: attempt
                )
                try ensureVideoCallStartIsCurrent(
                    generation: generation,
                    previewID: previewID,
                    scope: scope,
                    attempt: attempt
                )
                let remoteCall = rtcCall(response.call, withRTCToken: response.rtcToken)
                let initialMediaMode = Self.normalizedRTCMediaMode(remoteCall.mediaMode, fallback: "video")
                if initialMediaMode != attempt.mediaMode {
                    attempt = try rebindDirectCallAttempt(attempt, mediaMode: initialMediaMode)
                }
                let remoteStatus = response.call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard claimCallLifecycle(
                    callID: remoteCall.id,
                    direction: .outgoing,
                    stateVersion: remoteCall.stateVersion,
                    reason: "outgoing_video_created"
                ) else {
                    throw IMAPIError.server("视频通话状态已变化，请重试")
                }
                voiceCallSystem.reportOutgoingCallStarted(
                    callID: remoteCall.id,
                    peerName: target.name,
                    isVideo: true
                )
                if remoteStatus == "ringing" {
                    _ = advanceCallLifecycle(
                        callID: remoteCall.id,
                        to: .ringing,
                        stateVersion: remoteCall.stateVersion,
                        reason: "remote_ringing"
                    )
                }
                // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：沿用占位通话页 id，避免 fullScreenCover 重新弹出造成卡顿
                let pendingPresentation = pendingOutgoingVideoCallPresentation(for: attempt)
                var nextActiveCall = VoiceCallSession(
                    id: pendingPresentation?.id ?? "video-call-\(UUID().uuidString)",
                    callID: remoteCall.id,
                    roomID: remoteCall.roomID,
                    rtcToken: response.rtcToken,
                    mediaBaseURL: joined?.media.owtBaseURL ?? "",
                    peer: target,
                    direction: "呼出",
                    startedAt: "刚刚",
                    statusText: remoteStatus == "accepted" ? "连接中" : "等待对方接听",
                    mediaState: .preparing,
                    isMuted: pendingPresentation?.isMuted ?? false,
                    speakerOn: pendingPresentation?.speakerOn ?? true,
                    startedAtDate: startedAt,
                    connectedAt: nil,
                    requestedMediaMode: "video",
                    mediaMode: initialMediaMode,
                    localCameraEnabled: initialMediaMode == "video" && effectiveCameraEnabled,
                    stateVersion: remoteCall.stateVersion,
                    requiresAcceptedDeviceBeforeJoin: joined == nil
                )
                nextActiveCall.isMinimized = pendingPresentation?.isMinimized ?? false
                activeVoiceCall = nextActiveCall
                // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
                if previewID == nil || videoCallPreview?.id == previewID {
                    videoCallPreview = nil
                }
                if remoteStatus == "accepted", let joined {
                    let readyRoom = try await joinedRoomReadyForVoiceStart(
                        call: remoteCall,
                        joinedRoom: joined,
                        context: createdCallContext,
                        roomID: remoteCall.roomID,
                        rtcToken: response.rtcToken,
                        scope: scope,
                        attempt: attempt
                    )
                    guard isCurrentDirectCallAttempt(attempt),
                          directCallResourceIsOwned(callID: remoteCall.id, by: attempt),
                          activeVoiceCall?.callID == remoteCall.id else { return }
                    if initialMediaMode == "video" {
                        startVideoMediaSession(
                            call: remoteCall,
                            joinedRoom: readyRoom,
                            direction: "呼出",
                            peer: target,
                            cameraEnabled: effectiveCameraEnabled,
                            scope: scope,
                            attempt: attempt
                        )
                    } else {
                        startVoiceMediaSession(
                            call: remoteCall,
                            joinedRoom: readyRoom,
                            direction: "呼出",
                            peer: target,
                            scope: scope,
                            attempt: attempt
                        )
                    }
                } else {
                    scheduleOutgoingVoiceCallWatchdog(callID: remoteCall.id, scope: scope, timeoutSeconds: provider.callTimeoutSeconds)
                }
                if joined == nil {
                    ensureRTCSignalingRefreshActive(reason: "outgoing_policy_wait")
                    if remoteStatus == "accepted" {
                        startVoiceMediaSessionFromActiveCall(scope: scope, authoritativeCall: remoteCall)
                    }
                }
                if !cameraEnabled || effectiveCameraEnabled {
                    toast = nil
                }
            } catch {
                if let waitError = error as? RTCPeerParticipantWaitError {
                    if waitError == .timedOut || isCurrentRemoteScope(scope) {
                        return
                    }
                }
                if !createdCallID.isEmpty {
                    enqueueRTCTerminalCompensation(
                        callID: createdCallID,
                        action: .cancel,
                        reason: "video_start_failed",
                        context: createdCallContext
                    )
                }
                // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：发起失败时清理提前展示的空 callID 通话页，避免卡在视频页
                clearPendingOutgoingVideoCallPresentation(for: attempt)
                // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
                guard callStore.videoCallStartGeneration == generation,
                      isCurrentDirectCallAttempt(attempt) else { return }
                if !createdCallID.isEmpty,
                   activeVoiceCall?.callID == createdCallID {
                    finishVoiceCallFromRemote(
                        status: "连接失败",
                        subtitle: "视频通话 · 发起失败",
                        toastText: "视频通话发起失败",
                        endReason: "video_start_failed",
                        expectedCallID: createdCallID,
                        lifecyclePhase: .failure
                    )
                }
                if let previewID, videoCallPreview?.id == previewID {
                    videoCallPreview?.startError = videoCallPreviewStartErrorMessage(for: error)
                    toast = nil
                } else if isCurrentRemoteScope(scope) {
                    handleRemoteError(error, fallback: "视频通话服务暂不可用", rtcMedia: .video)
                }
            }
        }
    }

    private func ensureVideoCallStartIsCurrent(
        generation: UUID,
        previewID: String?,
        scope: String,
        attempt: DirectCallAttempt
    ) throws {
        guard callStore.videoCallStartGeneration == generation,
              isCurrentRemoteScope(scope),
              isCurrentDirectCallAttempt(attempt) else {
            throw CancellationError()
        }
        if let previewID, videoCallPreview?.id != previewID {
            throw CancellationError()
        }
    }

    private func finishVideoCallStartAttempt(generation: UUID, previewID: String?) {
        guard callStore.videoCallStartGeneration == generation else { return }
        callStore.videoCallStartGeneration = nil
        isStartingVideoCall = false
        if let previewID, videoCallPreview?.id == previewID {
            videoCallPreview?.isStartingCall = false
        }
    }

    private func videoCallPreviewStartErrorMessage(for error: Error) -> String {
        if error is CancellationError {
            return "登录状态已变化，请重新打开视频通话"
        }
        if let capabilityMessage = capabilityUserMessage(from: error, rtcMedia: .video) {
            return capabilityMessage
        }
        let detail = userFacingError(error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return "视频服务暂不可用，请稍后重试" }
        let normalizedDetail = detail.lowercased()
        if detail.contains("视频服务暂不可用")
            || detail.contains("服务不可用")
            || normalizedDetail.contains("service unavailable")
            || normalizedDetail.contains("provider unavailable")
            || normalizedDetail.contains("rtc_provider_unavailable") {
            return "视频服务暂不可用，请稍后重试"
        }
        if detail.contains("视频通话") || detail.contains("麦克风") || detail.contains("摄像头") {
            return detail
        }
        return "无法发起视频通话：\(detail)"
    }

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: complete acceptIncomingVideoCall implementation, including all failure cleanup branches.
    func acceptIncomingVideoCall(as mode: String, fromSystem: Bool = false) {
        guard let incoming = incomingVoiceCall, incoming.isVideo else { return }
        let normalizedMode = mode == "video" ? "video" : "audio"
        let systemCallID = incoming.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // WDT_IOS1_CALLKIT_ANSWER_20260921: both app UI and system UI share CallKit audio ownership.
        let usesSystemAudio = fromSystem || voiceCallSystem.hasPresentedCall(callID: systemCallID)
        guard guardCallLicenseForAction(normalizedMode == "video" ? .video : .voice) else {
            if usesSystemAudio {
                rollbackFailedSystemAnswer(callID: systemCallID, context: apiContext,
                    reason: "callkit_video_answer_license_unavailable", rejectServer: true,
                    preservingEstablishedCall: true)
            }
            return
        }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        if let answerMode = incomingCallAnswerMode {
            toast = answerMode == "video" ? "正在视频接听，请稍候" : "正在语音接听，请稍候"
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            if usesSystemAudio {
                rollbackFailedSystemAnswer(
                    callID: systemCallID,
                    context: context,
                    reason: "callkit_video_answer_session_unavailable",
                    rejectServer: false
                )
            }
            return
        }
        let scope = remoteDataScopeKey(for: context)
        var attempt = beginDirectCallAttempt(
            kind: .video,
            context: context,
            callID: incoming.callID ?? "",
            peerID: incoming.caller.id,
            mediaMode: normalizedMode
        )
        guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else { return }
        callStore.incomingCallAnswerOperationID = attempt.operationID
        incomingCallAnswerMode = normalizedMode
        Task {
            defer {
                if callStore.incomingCallAnswerOperationID == attempt.operationID {
                    callStore.incomingCallAnswerOperationID = nil
                    incomingCallAnswerMode = nil
                }
                finishDirectCallAttemptSetup(attempt)
            }
            var acceptedCallID = ""
            var acceptedCallContext = context
            var installedActiveCall = false
            do {
                if normalizedMode == "video" {
                    try await ensureRTCProviderReadyForVideoCall(context: context, scope: scope, attempt: attempt)
                } else {
                    try await ensureRTCProviderReadyForAudioCall(context: context, scope: scope, attempt: attempt)
                }
                let microphoneAuthorized = try await awaitDirectCallStage(attempt) {
                    await ensureMicrophonePermissionForVoiceCall()
                }
                guard microphoneAuthorized else {
                    toast = "需要麦克风权限才能接听通话"
                    if usesSystemAudio {
                        rollbackFailedSystemAnswer(
                            callID: systemCallID,
                            context: context,
                            reason: "callkit_video_answer_microphone_denied",
                            rejectServer: true
                        )
                    }
                    return
                }
                guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else { return }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: answer the already-presented system call before media setup.
                if usesSystemAudio && !fromSystem {
                    try await awaitDirectCallStage(attempt) {
                        try await voiceCallSystem.answerPresentedCall(callID: systemCallID)
                    }
                }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_END
                let cameraAvailable = videoMediaClient.cameraAvailable
                let cameraAuthorized = normalizedMode == "video" && cameraAvailable
                    ? try await awaitDirectCallStage(attempt) {
                        await ensureVideoPermission()
                    }
                    : false
                guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else { return }
                let answerPlan = RTCIncomingVideoAnswerPlan.resolve(
                    requestedMode: normalizedMode,
                    cameraAvailable: cameraAvailable,
                    cameraAuthorized: cameraAuthorized
                )
                if answerPlan.acceptedMode == "audio" {
                    guard guardCallLicenseForAction(.voice) else { return }
                }
                guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else { return }
                attempt = try rebindDirectCallAttempt(
                    attempt,
                    mediaMode: answerPlan.acceptedMode
                )
                let response = try await awaitDirectCallStage(attempt) {
                    let requestContext = try currentDirectCallRequestContext(context, attempt: attempt)
                    acceptedCallContext = requestContext
                    return try await api.acceptRTCCall(
                        context: requestContext,
                        callID: incoming.callID ?? "",
                        mode: answerPlan.acceptedMode,
                        capabilities: localVideoCapabilities
                    )
                }
                acceptedCallID = response.call.id.isEmpty
                    ? incoming.callID ?? ""
                    : response.call.id
                attempt = try rebindDirectCallAttempt(
                    attempt,
                    callID: acceptedCallID
                )
                registerAcceptedDirectCallCleanupObligation(
                    context: acceptedCallContext,
                    callID: acceptedCallID,
                    attempt: attempt
                )
                guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else {
                    if !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                let joined = try await awaitDirectCallStage(attempt) {
                    try await api.joinRTCRoom(
                        context: currentDirectCallRequestContext(acceptedCallContext, attempt: attempt),
                        roomID: response.call.roomID,
                        rtcToken: response.rtcToken
                    )
                }
                guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else {
                    if !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                let remoteCall = rtcCall(response.call, withRTCToken: response.rtcToken)
                let acceptedMediaMode = Self.normalizedRTCMediaMode(
                    remoteCall.mediaMode,
                    fallback: answerPlan.acceptedMode
                )
                if acceptedMediaMode != attempt.mediaMode {
                    attempt = try rebindDirectCallAttempt(attempt, mediaMode: acceptedMediaMode)
                }
                _ = advanceCallLifecycle(
                    callID: remoteCall.id,
                    to: .dialing,
                    stateVersion: remoteCall.stateVersion > 0 ? remoteCall.stateVersion : nil,
                    reason: "incoming_video_answered_media_connecting"
                )
                activeVoiceCall = VoiceCallSession(
                    id: "video-call-\(UUID().uuidString)",
                    callID: remoteCall.id,
                    roomID: remoteCall.roomID,
                    rtcToken: response.rtcToken,
                    mediaBaseURL: joined.media.owtBaseURL,
                    peer: incoming.caller,
                    direction: "来电",
                    startedAt: incoming.startedAt,
                    statusText: "连接中",
                    mediaState: .connecting,
                    isMuted: false,
                    speakerOn: true,
                    startedAtDate: Date(),
                    connectedAt: nil,
                    requestedMediaMode: "video",
                    mediaMode: acceptedMediaMode,
                    localCameraEnabled: acceptedMediaMode == "video" && answerPlan.cameraEnabled,
                    stateVersion: remoteCall.stateVersion
                )
                installedActiveCall = true
                if let notice = answerPlan.notice {
                    toast = notice
                }
                incomingVoiceCall = nil
                let readyRoom = try await joinedRoomReadyForVoiceStart(
                    call: remoteCall,
                    joinedRoom: joined,
                    context: acceptedCallContext,
                    roomID: remoteCall.roomID,
                    rtcToken: response.rtcToken,
                    scope: scope,
                    attempt: attempt
                )
                guard isCurrentDirectCallAttempt(attempt),
                      directCallResourceIsOwned(callID: remoteCall.id, by: attempt),
                      activeVoiceCall?.callID == remoteCall.id else {
                    clearActiveDirectCallResourceIfOwned(
                        callID: remoteCall.id,
                        by: attempt,
                        reason: "incoming_video_scope_changed"
                    )
                    if !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: video and video-as-audio also await system activation.
                if usesSystemAudio {
                    try await waitForCallKitAudioSessionBeforeVoiceStart(callID: remoteCall.id, scope: scope, attempt: attempt)
                }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_END
                if acceptedMediaMode == "video" {
                    startVideoMediaSession(
                        call: remoteCall,
                        joinedRoom: readyRoom,
                        direction: "来电",
                        peer: incoming.caller,
                        cameraEnabled: answerPlan.cameraEnabled,
                        scope: scope,
                        attempt: attempt
                    )
                } else {
                    startVoiceMediaSession(
                        call: remoteCall,
                        joinedRoom: readyRoom,
                        direction: "来电",
                        peer: incoming.caller,
                        scope: scope,
                        attempt: attempt
                    )
                }
                resolveDirectCallCleanupObligations(for: attempt)
            } catch {
                if let waitError = error as? RTCPeerParticipantWaitError {
                    if waitError == .timedOut,
                       isCurrentDirectCallAttempt(attempt) {
                        if usesSystemAudio {
                            rollbackFailedSystemAnswer(
                                callID: acceptedCallID.isEmpty ? systemCallID : acceptedCallID,
                                context: context,
                                reason: "callkit_video_answer_peer_timeout",
                                rejectServer: acceptedCallID.isEmpty
                            )
                        }
                        return
                    }
                }
                guard isCurrentDirectCallAttempt(attempt) else {
                    if usesSystemAudio, acceptedCallID.isEmpty {
                        rollbackUnconnectedSystemAnswerIfOwned(attempt: attempt, context: context)
                    }
                    clearActiveDirectCallResourceIfOwned(
                        callID: acceptedCallID,
                        by: attempt,
                        reason: "incoming_video_scope_changed"
                    )
                    if !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                if installedActiveCall {
                    guard directCallResourceIsOwned(callID: acceptedCallID, by: attempt),
                          activeVoiceCall?.callID == acceptedCallID else { return }
                    stopCallMediaSession(
                        for: activeVoiceCall,
                        reason: "incoming_video_setup_failed"
                    )
                    _ = advanceCallLifecycle(
                        callID: acceptedCallID,
                        to: .failure,
                        reason: "incoming_video_setup_failed"
                    )
                    activeVoiceCall = nil
                    if !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: rtcCallFailureReason(
                                for: error,
                                defaultReason: "media_setup_failed"
                            )
                        )
                    }
                    if usesSystemAudio {
                        rollbackFailedSystemAnswer(
                            callID: acceptedCallID,
                            context: context,
                            reason: "callkit_video_answer_setup_failed",
                            rejectServer: false
                        )
                    }
                    handleRemoteError(error, fallback: "接听视频通话失败", rtcMedia: .video)
                    return
                }
                guard isCurrentIncomingVideoAnswer(incoming, attempt: attempt) else { return }
                if !acceptedCallID.isEmpty {
                    _ = advanceCallLifecycle(
                        callID: acceptedCallID,
                        to: .failure,
                        reason: "incoming_video_answer_failed"
                    )
                    incomingVoiceCall = nil
                    await hangupDirectCallResourceIfOwned(
                        context: acceptedCallContext,
                        callID: acceptedCallID,
                        by: attempt,
                        reason: rtcCallFailureReason(
                            for: error,
                            defaultReason: "network_error"
                        )
                    )
                }
                if usesSystemAudio {
                    rollbackFailedSystemAnswer(
                        callID: acceptedCallID.isEmpty ? systemCallID : acceptedCallID,
                        context: context,
                        reason: "callkit_video_answer_failed",
                        rejectServer: acceptedCallID.isEmpty
                    )
                }
                handleRemoteError(error, fallback: "接听视频通话失败", rtcMedia: .video)
            }
        }
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END: complete acceptIncomingVideoCall implementation.

    private func isCurrentIncomingVideoAnswer(
        _ expected: IncomingVoiceCall,
        attempt: DirectCallAttempt
    ) -> Bool {
        guard attempt.kind == .video,
              isCurrentDirectCallAttempt(attempt),
              let current = incomingVoiceCall,
              current.isVideo,
              current.id == expected.id,
              current.caller.id == attempt.peerID else {
            return false
        }
        let expectedCallID = expected.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentCallID = current.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !expectedCallID.isEmpty
            && currentCallID == expectedCallID
            && currentCallID == attempt.callID
    }

    @discardableResult
    private func ensureRTCProviderReadyForVideoCall(
        context: IMAPIContext,
        scope: String,
        attempt: DirectCallAttempt
    ) async throws -> RemoteRTCProvider {
        let config = try await awaitDirectCallStage(attempt) {
            try await currentFileUploadConfig(
                context: currentDirectCallRequestContext(context, attempt: attempt),
                scope: scope
            )
        }
        try requireRTCLicense(config.videoCallLicenseKnown ? config.videoCallEnabled : nil, media: .video)
        let provider = try await currentRTCProviderForCall(context: context, attempt: attempt)
        try requireVideoProviderCapabilities(provider)
        return provider
    }

    private func requireVideoProviderCapabilities(_ provider: RemoteRTCProvider) throws {
        try requireRTCLicense(provider.videoCallEnabled, media: .video)
        guard provider.supportsVideo else {
            throw IMAPIError.server("对方版本或当前服务暂不支持视频通话")
        }
        guard provider.mediaPlaneConfigured, provider.iceServersConfigured else {
            throw IMAPIError.server("视频服务媒体配置缺失，请联系管理员")
        }
    }

    private func ensureVideoPermission() async -> Bool {
        if let videoPermissionDecisionOverride {
            return await videoPermissionDecisionOverride()
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startOutgoingVoiceCall(to peer: IMUser? = nil, channelID: String? = nil) {
        guard guardCallLicenseForAction(.voice) else { return }
        guard !isStartingVoiceCall else {
            toast = "正在发起语音通话，请稍候"
            return
        }
        discardUnownedLegacyCallViews(reason: "outgoing_voice_truth_reconcile")
        guard !hasTruthfulCallOwnership else {
            toast = incomingVoiceCall != nil ? "请先处理当前来电" : "当前正在通话中"
            return
        }
        guard let target = peer, !isCurrentUserProfile(target) else {
            toast = DirectConversationCallPeerResolver.unavailableMessage
            return
        }
        if let reason = voiceCallUnavailableReason(for: target) {
            toast = reason
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            toast = "登录会话不可用，请重新登录"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        var attempt = beginDirectCallAttempt(
            kind: .voice,
            context: context,
            peerID: target.id,
            mediaMode: "audio"
        )
        toast = "正在发起语音通话"
        isStartingVoiceCall = true
        let callStartedAt = Date()
        let callChannelID = voiceCallChannelID(for: target, requestedChannelID: channelID)
        Task {
            defer { finishDirectCallAttemptSetup(attempt) }
            var createdCallID: String?
            var createdCallContext = context
            do {
                let provider = try await ensureRTCProviderReadyForAudioCall(
                    context: context,
                    scope: scope,
                    attempt: attempt
                )
                let microphoneAuthorized = try await awaitDirectCallStage(attempt) {
                    await ensureMicrophonePermissionForVoiceCall()
                }
                guard microphoneAuthorized else { return }
                try configureAudioSessionForVoiceCall()
                let response = try await awaitDirectCallStage(attempt) {
                    let requestContext = try currentDirectCallRequestContext(context, attempt: attempt)
                    createdCallContext = requestContext
                    return try await api.createRTCCall(
                        context: requestContext,
                        calleeUID: target.id,
                        callType: "audio",
                        channelID: callChannelID
                    )
                }
                createdCallID = response.call.id
                attempt = try rebindDirectCallAttempt(
                    attempt,
                    callID: response.call.id
                )
                guard isCurrentDirectCallAttempt(attempt) else {
                    releaseAudioSessionForVoiceCall()
                    if !response.call.id.isEmpty {
                        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                        let cleanupCallID = response.call.id
                        let idempotencyKey = makeRTCTerminalCompensationIdempotencyKey(action: .cancel)
                        Task {
                            try? await api.cancelRTCCall(
                                context: createdCallContext,
                                callID: cleanupCallID,
                                reason: "client_scope_changed",
                                idempotencyKey: idempotencyKey
                            )
                        }
                        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    }
                    return
                }
                let joinedRoom = try await initialOutgoingRoomJoin(
                    response: response, context: createdCallContext, attempt: attempt
                )
                let remoteCall = rtcCall(response.call, withRTCToken: response.rtcToken)
                guard isCurrentDirectCallAttempt(attempt) else {
                    releaseAudioSessionForVoiceCall()
                    if !response.call.id.isEmpty {
                        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                        let cleanupCallID = response.call.id
                        let idempotencyKey = makeRTCTerminalCompensationIdempotencyKey(action: .cancel)
                        Task {
                            try? await api.cancelRTCCall(
                                context: createdCallContext,
                                callID: cleanupCallID,
                                reason: "client_scope_changed",
                                idempotencyKey: idempotencyKey
                            )
                        }
                        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    }
                    return
                }
                let remoteStatus = response.call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard claimCallLifecycle(
                    callID: remoteCall.id,
                    direction: .outgoing,
                    stateVersion: remoteCall.stateVersion,
                    reason: "outgoing_voice_created"
                ) else {
                    throw IMAPIError.server("语音通话状态已变化，请重试")
                }
                voiceCallSystem.reportOutgoingCallStarted(
                    callID: remoteCall.id,
                    peerName: target.name,
                    isVideo: false
                )
                if remoteStatus == "ringing" {
                    _ = advanceCallLifecycle(
                        callID: remoteCall.id,
                        to: .ringing,
                        stateVersion: remoteCall.stateVersion,
                        reason: "remote_ringing"
                    )
                }
                activeVoiceCall = VoiceCallSession(
                    id: "call_\(UUID().uuidString)",
                    callID: remoteCall.id,
                    roomID: remoteCall.roomID,
                    rtcToken: response.rtcToken,
                    mediaBaseURL: joinedRoom?.media.owtBaseURL ?? "",
                    peer: target,
                    direction: "呼出",
                    startedAt: "刚刚",
                    statusText: remoteStatus == "accepted" ? "连接中" : "等待对方接听",
                    mediaState: .preparing,
                    isMuted: false,
                    speakerOn: true,
                    startedAtDate: callStartedAt,
                    connectedAt: nil,
                    stateVersion: remoteCall.stateVersion,
                    requiresAcceptedDeviceBeforeJoin: joinedRoom == nil
                )
                if remoteStatus == "accepted", let joinedRoom {
                    cancelVoiceCallWatchdog()
                    let readyRoom = try await joinedRoomReadyForVoiceStart(
                        call: remoteCall,
                        joinedRoom: joinedRoom,
                        context: createdCallContext,
                        roomID: remoteCall.roomID,
                        rtcToken: response.rtcToken,
                        scope: scope,
                        attempt: attempt
                    )
                    guard isCurrentDirectCallAttempt(attempt),
                          directCallResourceIsOwned(callID: remoteCall.id, by: attempt),
                          activeVoiceCall?.callID == remoteCall.id else { return }
                    startVoiceMediaSession(
                        call: remoteCall,
                        joinedRoom: readyRoom,
                        direction: "呼出",
                        peer: target,
                        scope: scope,
                        attempt: attempt
                    )
                } else {
                    scheduleOutgoingVoiceCallWatchdog(callID: remoteCall.id, scope: scope, timeoutSeconds: provider.callTimeoutSeconds)
                }
                if joinedRoom == nil {
                    ensureRTCSignalingRefreshActive(reason: "outgoing_policy_wait")
                    if remoteStatus == "accepted" {
                        startVoiceMediaSessionFromActiveCall(scope: scope, authoritativeCall: remoteCall)
                    }
                }
                upsertVoiceCallRecord(
                    callID: remoteCall.id,
                    title: target.name,
                    subtitle: "语音呼出 · 正在呼叫",
                    status: "呼叫中",
                    direction: .outgoing,
                    peer: target,
                    startedAt: callStartedAt,
                    endedAt: nil,
                    durationSeconds: nil
                )
                toast = "已发起语音通话"
            } catch {
                releaseAudioSessionForVoiceCall()
                if let waitError = error as? RTCPeerParticipantWaitError {
                    if waitError == .timedOut || isCurrentDirectCallAttempt(attempt) {
                        return
                    }
                }
                if let createdCallID, !createdCallID.isEmpty {
                    enqueueRTCTerminalCompensation(
                        callID: createdCallID,
                        action: .cancel,
                        reason: rtcCallFailureReason(for: error, defaultReason: "network_error"),
                        context: createdCallContext
                    )
                }
                guard isCurrentDirectCallAttempt(attempt) else {
                    return
                }
                if let createdCallID, !createdCallID.isEmpty,
                   activeVoiceCall?.callID == createdCallID {
                    finishVoiceCallFromRemote(
                        status: "连接失败",
                        subtitle: "语音通话 · 发起失败",
                        toastText: "语音通话发起失败",
                        endReason: "voice_start_failed",
                        expectedCallID: createdCallID,
                        lifecyclePhase: .failure
                    )
                }
                if isRTCBusyConflict(error) {
                    await refreshRTCCallEventsSilently(context: context, scope: scope)
                }
                handleRemoteError(error, fallback: "语音通话服务暂不可用", rtcMedia: .voice)
            }
        }
    }

    private func initialOutgoingRoomJoin(
        response: RemoteRTCCallResponse,
        context: IMAPIContext,
        attempt: DirectCallAttempt
    ) async throws -> RemoteRTCRoomJoinData? {
        try ensureDirectCallAttemptIsCurrent(attempt)
        guard !response.requiresAcceptedDeviceBeforeJoin else { return nil }
        do {
            return try await awaitDirectCallStage(attempt) {
                try await api.joinRTCRoom(
                    context: currentDirectCallRequestContext(context, attempt: attempt),
                    roomID: response.call.roomID,
                    rtcToken: response.rtcToken
                )
            }
        } catch {
            // A provider rollout can race the legacy observation; preserve the call.
            if Self.isRTCTransportPolicyPending(error) { return nil }
            throw error
        }
    }

    static func isRTCTransportPolicyPending(_ error: Error) -> Bool {
        guard case let IMAPIError.conflict(code, _) = error else { return false }
        return code == "rtc_transport_policy_pending"
    }

    static func hasBoundAcceptedOutgoingCall(
        _ remote: RemoteRTCCall?, callID: String, roomID: String,
        callerUID: String, callerDeviceID: String, callerAppID: String,
        calleeUID: String, minimumStateVersion: Int64
    ) -> Bool {
        // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: Android accepted-device appID can be absent; bind by uid/device.
        guard let remote, remote.id == callID, remote.roomID == roomID,
              remote.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "accepted",
              remote.stateVersion >= minimumStateVersion,
              remote.callerUID == callerUID, remote.calleeUID == calleeUID,
              let caller = remote.callerDevice, let accepted = remote.acceptedDevice,
              !callerDeviceID.isEmpty, !callerAppID.isEmpty,
              caller.uid == callerUID, caller.deviceID == callerDeviceID, caller.appID == callerAppID,
              accepted.uid == calleeUID,
              !accepted.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END
        return true
    }

    private func isRTCBusyConflict(_ error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else { return false }
        if case let .conflict(code, _) = apiError {
            return ["duplicate_call", "caller_busy", "callee_busy"].contains(code)
        }
        return false
    }

    @discardableResult
    private func ensureRTCProviderReadyForAudioCall(
        context: IMAPIContext,
        scope: String,
        attempt: DirectCallAttempt
    ) async throws -> RemoteRTCProvider {
        let config = try await awaitDirectCallStage(attempt) {
            try await currentFileUploadConfig(
                context: currentDirectCallRequestContext(context, attempt: attempt),
                scope: scope
            )
        }
        try requireRTCLicense(config.voiceCallLicenseKnown ? config.voiceCallEnabled : nil, media: .voice)
        let provider = try await currentRTCProviderForCall(context: context, attempt: attempt)
        try requireRTCLicense(provider.voiceCallEnabled, media: .voice)
        guard provider.supportsAudio else {
            throw IMAPIError.server("当前仅支持语音通话")
        }
        guard provider.mediaPlaneConfigured, provider.iceServersConfigured else {
            throw IMAPIError.server("语音服务媒体配置缺失，请联系管理员")
        }
        return provider
    }

    private func startVoiceMediaSession(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData,
        direction: String,
        peer: IMUser,
        scope: String,
        attempt: DirectCallAttempt? = nil
    ) {
        if let attempt {
            guard isCurrentDirectCallAttempt(attempt),
                  directCallResourceIsOwned(callID: call.id, by: attempt) else { return }
        }
        guard isVoiceMediaClientAvailable else {
            voiceDebug("start_skipped unavailable")
            return
        }
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty else {
            voiceDebug("start_skipped empty_call_id")
            return
        }
        guard activeVoiceCall?.callID == callID else {
            voiceDebug("start_skipped active_mismatch call=\(Self.shortDebugID(callID)) active=\(Self.shortDebugID(activeVoiceCall?.callID ?? ""))")
            return
        }
        guard activeVoiceMediaCallID != callID else {
            voiceDebug("start_skipped already_started call=\(Self.shortDebugID(callID))")
            return
        }
        let selfParticipant = joinedRoom.selfParticipant
        let peerResolution = rtcPeerParticipantResolution(call: call, joinedRoom: joinedRoom)
        let peerParticipant = peerResolution?.participant
        let roomID = call.roomID.isEmpty ? joinedRoom.roomID : call.roomID
        let rtcToken = joinedRoom.rtcToken.isEmpty ? call.rtcToken : joinedRoom.rtcToken
        let selfParticipantDeviceID = selfParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiContextDeviceID = apiContext.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let localDeviceID = selfParticipantDeviceID.isEmpty ? apiContextDeviceID : selfParticipantDeviceID
        let localDeviceSource = selfParticipantDeviceID.isEmpty ? "api_context" : "self_participant"
        let peerParticipantDeviceID = peerParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let peerDeviceID = peerParticipantDeviceID
        let peerDeviceSource: String
        if !peerParticipantDeviceID.isEmpty {
            peerDeviceSource = peerResolution?.source ?? "participant"
        } else {
            peerDeviceSource = "missing"
        }
        guard !roomID.isEmpty, !rtcToken.isEmpty else {
            voiceDebug("start_failed missing_room_or_token call=\(Self.shortDebugID(callID))")
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：本机媒体启动前置资料缺失不再伪装成 ICE 失败
            handleVoiceMediaEvent(.mediaStartFailed, callID: callID, scope: scope)
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return
        }
        guard !localDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            voiceDebug("start_failed missing_self_device call=\(Self.shortDebugID(callID))")
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            handleVoiceMediaEvent(.mediaStartFailed, callID: callID, scope: scope)
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return
        }
        guard !peerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            voiceDebug("start_failed missing_peer_device call=\(Self.shortDebugID(callID))")
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            handleVoiceMediaEvent(.mediaStartFailed, callID: callID, scope: scope)
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return
        }
        activeVoiceMediaCallID = callID
        startRTCMediaStateHeartbeat(
            callID: callID,
            roomID: roomID,
            rtcToken: rtcToken,
            joinedRoom: joinedRoom,
            scope: scope,
            attempt: attempt
        )
        let mediaGeneration = rtcMediaHeartbeatGeneration
        AccessDiagnostics.shared.recordTurnServers(urls: joinedRoom.media.iceServers.flatMap(\.urls), callID: callID)
        let context = VoiceMediaSessionContext(
            callID: callID,
            roomID: roomID,
            rtcToken: rtcToken,
            direction: direction,
            localUID: selfParticipant?.uid ?? (apiContext.imUID ?? currentUser.id),
            localDeviceID: localDeviceID,
            localDeviceSource: localDeviceSource,
            peerUID: peerParticipant?.uid ?? peer.id,
            peerDeviceID: peerDeviceID,
            peerDeviceSource: peerDeviceSource,
            mediaBaseURL: joinedRoom.media.owtBaseURL,
            iceServers: joinedRoom.media.iceServers,
            iceCredentialExpiresAt: joinedRoom.media.iceCredentialExpiresAt,
            iceCredentialRefreshAfter: joinedRoom.media.iceCredentialRefreshAfter,
            icePolicy: joinedRoom.media.icePolicy ?? .legacy,
            postSignal: { [weak self] envelope, activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                return try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.postRTCSignalV2(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken,
                        envelope: envelope
                    )
                }
            },
            pollSignals: { [weak self] cursor, activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                return try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.pollRTCSignalsV2(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken,
                        cursor: cursor,
                        limit: 100,
                        waitMS: 25_000
                    )
                }
            },
            acknowledgeSignals: { [weak self] cursor, activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.ackRTCSignals(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken,
                        cursor: cursor
                    )
                }
            },
            refreshIceCredentials: { [weak self] activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                let refreshed = try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.refreshRTCIceCredentials(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken
                    )
                }
                AccessDiagnostics.shared.recordTurnServers(urls: refreshed.iceServers.flatMap(\.urls), callID: callID)
                return refreshed
            }
        )
        voiceDebug(
            "start_context call=\(Self.shortDebugID(callID)) dir=\(direction) room=\(!roomID.isEmpty) token=\(!rtcToken.isEmpty) selfDevice=\(!localDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) peerDevice=\(!context.peerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) peerUID=\(!context.peerUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ice=\(joinedRoom.media.iceServers.count) participants=\(joinedRoom.participants.count) selfParticipant=\(selfParticipant != nil) peerParticipant=\(peerParticipant != nil) acceptedDevice=\(call.acceptedDevice?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)"
        )
        voiceMediaEventTask?.cancel()
        voiceMediaEventTask = Task { [weak self, voiceMediaClient] in
            guard let self else { return }
            do {
                self.voiceDebug("client_start_call call=\(Self.shortDebugID(callID))")
                // JHT_MOD_BEGIN IOS_RTC_RECEIVER_MEDIA_START_RETRY_20260917 - 修改开始：接收方音频会话刚切换时，媒体启动瞬时失败先短暂重试，避免接听后立即结束
                let events = try await self.startVoiceMediaClientWithStartupRetry(
                    voiceMediaClient,
                    context: context,
                    attempt: attempt
                )
                // JHT_MOD_END IOS_RTC_RECEIVER_MEDIA_START_RETRY_20260917 - 修改结束
                let speakerOn = self.activeVoiceCall?.speakerOn ?? true
                await voiceMediaClient.setSpeakerEnabled(speakerOn)
                for await event in events {
                    guard !Task.isCancelled else { break }
                    guard attempt.map({ self.isCurrentDirectCallAttempt($0) || self.isCurrentRTCMediaOperation($0.operationID) }) ?? true else {
                        break
                    }
                    self.handleVoiceMediaEvent(
                        event,
                        callID: callID,
                        scope: scope,
                        operationID: attempt?.operationID
                    )
                }
            } catch {
                guard attempt.map(self.isCurrentDirectCallAttempt) ?? true else {
                    return
                }
                // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：媒体启动抛错保留阶段语义，不再归类为真实 ICE 失败
                self.voiceDebug("client_start_failed stage=media_start call=\(Self.shortDebugID(callID)) error=\(Self.safeVoiceErrorSummary(error))")
                self.handleVoiceMediaEvent(
                    .mediaStartFailed,
                    callID: callID,
                    scope: scope,
                    operationID: attempt?.operationID
                )
                // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            }
        }
    }

    // JHT_MOD_BEGIN IOS_RTC_RECEIVER_MEDIA_START_RETRY_20260917 - 修改开始：仅对接收方媒体启动做短重试，呼出方保持原有首错即停语义
    private func startVoiceMediaClientWithStartupRetry(
        _ voiceMediaClient: any VoiceMediaClient,
        context: VoiceMediaSessionContext,
        attempt: DirectCallAttempt?
    ) async throws -> AsyncStream<RTCVoiceMediaEvent> {
        let maxAttempts = context.isCaller ? 1 : 3
        var startAttempt = 1
        while true {
            do {
                return try await awaitDirectCallStage(attempt) {
                    try await voiceMediaClient.start(context: context)
                }
            } catch {
                guard startAttempt < maxAttempts,
                      shouldRetryVoiceMediaStartup(error) else {
                    throw error
                }
                voiceDebug(
                    "client_start_retry call=\(Self.shortDebugID(context.callID)) attempt=\(startAttempt + 1) error=\(Self.safeVoiceErrorSummary(error))"
                )
                if let attempt {
                    try ensureDirectCallAttemptIsCurrent(attempt)
                } else if Task.isCancelled {
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: UInt64(startAttempt) * 250_000_000)
                if let attempt {
                    try ensureDirectCallAttemptIsCurrent(attempt)
                } else if Task.isCancelled {
                    throw CancellationError()
                }
                startAttempt += 1
            }
        }
    }

    private func shouldRetryVoiceMediaStartup(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        guard let apiError = error as? IMAPIError else {
            return true
        }
        switch apiError {
        case let .server(message):
            let normalized = message.lowercased()
            if normalized.contains("ice 配置缺失")
                || normalized.contains("房间信息不完整")
                || normalized.contains("设备信息不完整") {
                return false
            }
            return normalized.contains("audio")
                || normalized.contains("microphone")
                || normalized.contains("peerconnection")
                || normalized.contains("track")
                || normalized.contains("音频")
                || normalized.contains("麦克风")
                || normalized.contains("轨道")
        default:
            return false
        }
    }
    // JHT_MOD_END IOS_RTC_RECEIVER_MEDIA_START_RETRY_20260917 - 修改结束

    private func startVoiceMediaSessionFromActiveCall(
        scope: String,
        authoritativeCall: RemoteRTCCall? = nil
    ) {
        guard isCurrentRemoteScope(scope), !isEndingActiveCall else { return }
        guard let call = activeVoiceCall else {
            voiceDebug("join_skipped no_active_call")
            return
        }
        let callID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let roomID = call.roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rtcToken = call.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty else {
            voiceDebug("join_skipped empty_call_id")
            return
        }
        guard !roomID.isEmpty else {
            voiceDebug("join_skipped empty_room call=\(Self.shortDebugID(callID))")
            return
        }
        guard !rtcToken.isEmpty else {
            voiceDebug("join_skipped empty_token call=\(Self.shortDebugID(callID))")
            return
        }
        guard call.isVideoCall ? activeVideoMediaCallID != callID : activeVoiceMediaCallID != callID else {
            voiceDebug("join_skipped already_started call=\(Self.shortDebugID(callID))")
            return
        }
        guard pendingVoiceMediaJoinCallID != callID else {
            voiceDebug("join_skipped pending call=\(Self.shortDebugID(callID))")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            voiceDebug("join_failed no_im_session call=\(Self.shortDebugID(callID))")
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            handleVoiceMediaEvent(.mediaStartFailed, callID: callID, scope: scope)
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return
        }
        guard !call.requiresAcceptedDeviceBeforeJoin || Self.hasBoundAcceptedOutgoingCall(
            authoritativeCall, callID: callID, roomID: roomID,
            callerUID: context.imUID ?? currentUser.id,
            callerDeviceID: context.deviceID, callerAppID: context.appID,
            calleeUID: call.peer.id, minimumStateVersion: call.stateVersion
        ) else { return } // Existing signaling loop retries with authoritative call readback.
        if call.requiresAcceptedDeviceBeforeJoin {
            // The authenticated winner ends the ringing deadline. The server's
            // accepted-call deadline and existing signaling loop govern pending join.
            cancelVoiceCallWatchdog()
        }
        voiceDebug("join_start call=\(Self.shortDebugID(callID)) room=\(!roomID.isEmpty)")
        let directCallAttempt = directCallAttemptForActiveCall(call)
        pendingVoiceMediaJoinCallID = callID
        Task { [weak self] in
            defer {
                if self?.pendingVoiceMediaJoinCallID == callID {
                    self?.pendingVoiceMediaJoinCallID = nil
                }
            }
            do {
                guard let self, self.isCurrentRemoteScope(scope), !self.isEndingActiveCall,
                      self.activeVoiceCall?.callID == callID,
                      self.rtcTerminalMarkersByCallID[callID] == nil else { return }
                let joinedRoom = try await self.awaitDirectCallStage(directCallAttempt) {
                    try await self.api.joinRTCRoom(
                        context: self.currentDirectCallRequestContext(context, attempt: directCallAttempt),
                        roomID: roomID,
                        rtcToken: rtcToken
                    )
                }
                let activeCallID = self.activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard self.isCurrentRemoteScope(scope) else {
                    self.voiceDebug("join_aborted scope_changed call=\(Self.shortDebugID(callID))")
                    return
                }
                guard activeCallID == callID, !self.isEndingActiveCall, self.rtcTerminalMarkersByCallID[callID] == nil else {
                    self.voiceDebug("join_aborted active_mismatch call=\(Self.shortDebugID(callID)) active=\(Self.shortDebugID(activeCallID))")
                    return
                }
                if var current = self.activeVoiceCall {
                    current.mediaBaseURL = joinedRoom.media.owtBaseURL
                    self.activeVoiceCall = current
                }
                let localUID = (context.imUID ?? self.currentUser.id).trimmingCharacters(in: .whitespacesAndNewlines)
                let peerUID = call.peer.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let reconstructedCall = RemoteRTCCall(
                    id: callID,
                    status: "accepted",
                    roomID: roomID,
                    rtcToken: rtcToken,
                    callerUID: call.direction == "呼出" ? localUID : peerUID,
                    calleeUID: call.direction == "呼出" ? peerUID : localUID,
                    channelID: "",
                    channelType: "direct",
                    callType: call.isVideoCall ? "video" : "audio",
                    requestedMediaMode: call.requestedMediaMode,
                    mediaMode: call.mediaMode
                )
                let remoteCall: RemoteRTCCall
                if let authoritativeCall,
                   authoritativeCall.id.trimmingCharacters(in: .whitespacesAndNewlines) == callID {
                    remoteCall = self.rtcCall(authoritativeCall, withRTCToken: rtcToken)
                } else {
                    remoteCall = reconstructedCall
                }
                let readyRoom = try await self.joinedRoomReadyForVoiceStart(
                    call: remoteCall,
                    joinedRoom: joinedRoom,
                    context: context,
                    roomID: roomID,
                    rtcToken: rtcToken,
                    scope: scope,
                    attempt: directCallAttempt
                )
                guard directCallAttempt.map(self.isCurrentDirectCallAttempt) ?? true,
                      self.isCurrentRemoteScope(scope),
                      !self.isEndingActiveCall,
                      self.rtcTerminalMarkersByCallID[callID] == nil,
                      self.activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
                    self.voiceDebug("join_aborted before_start call=\(Self.shortDebugID(callID))")
                    return
                }
                let latestCall = self.activeVoiceCall ?? call
                if latestCall.isVideoCall, latestCall.mediaMode == "video" {
                    self.startVideoMediaSession(
                        call: remoteCall,
                        joinedRoom: readyRoom,
                        direction: latestCall.direction,
                        peer: latestCall.peer,
                        cameraEnabled: latestCall.localCameraEnabled,
                        scope: scope,
                        attempt: directCallAttempt
                    )
                } else {
                    self.startVoiceMediaSession(
                        call: remoteCall,
                        joinedRoom: readyRoom,
                        direction: call.direction,
                        peer: call.peer,
                        scope: scope,
                        attempt: directCallAttempt
                    )
                }
            } catch {
                guard directCallAttempt.map({ self?.isCurrentDirectCallAttempt($0) == true }) ?? true else {
                    return
                }
                if Self.isRTCTransportPolicyPending(error) {
                    return // Keep ringing/connecting; the existing signaling tick retries acceptance.
                }
                self?.voiceDebug("join_failed call=\(Self.shortDebugID(callID)) error=\(Self.safeVoiceErrorSummary(error))")
                if error is RTCPeerParticipantWaitError {
                    return
                }
                // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：join/准备失败不是 ICE 传输失败
                self?.handleVoiceMediaEvent(.mediaStartFailed, callID: callID, scope: scope)
                // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            }
        }
    }

    private func joinedRoomReadyForVoiceStart(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData,
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        scope: String,
        policy: RTCPeerParticipantWaitPolicy = .production,
        attempt: DirectCallAttempt? = nil
    ) async throws -> RemoteRTCRoomJoinData {
        if let attempt {
            try ensureDirectCallAttemptIsCurrent(attempt)
        }
        var current = normalizedJoinedRoom(joinedRoom, call: call, context: context, roomID: roomID, rtcToken: rtcToken)
        voiceDebug(Self.voiceJoinSummary(callID: call.id, joinedRoom: current))
        if joinedRoomPeerParticipant(call: call, joinedRoom: current) != nil {
            return current
        }
        markActiveCallWaitingForPeer(callID: call.id)
        let maximumAttempts = max(1, policy.maximumAttempts)
        for pollAttempt in 1...maximumAttempts {
            try ensureRTCParticipantWaitIsCurrent(
                callID: call.id,
                scope: scope,
                directCallAttempt: attempt
            )
            if pollAttempt > 1 {
                do {
                    try await Task.sleep(nanoseconds: policy.pollIntervalNanoseconds)
                } catch {
                    throw RTCPeerParticipantWaitError.cancelled
                }
            }
            try ensureRTCParticipantWaitIsCurrent(
                callID: call.id,
                scope: scope,
                directCallAttempt: attempt
            )
            let participants = try await awaitDirectCallStage(attempt) {
                try await api.listRTCRoomParticipants(
                    context: currentDirectCallRequestContext(context, attempt: attempt),
                    roomID: roomID,
                    rtcToken: rtcToken
                )
            }
            try ensureRTCParticipantWaitIsCurrent(
                callID: call.id,
                scope: scope,
                directCallAttempt: attempt
            )
            current = normalizedJoinedRoom(
                current,
                call: call,
                context: context,
                roomID: roomID,
                rtcToken: rtcToken,
                participants: participants
            )
            let peerIsReady = joinedRoomPeerParticipant(call: call, joinedRoom: current) != nil
            voiceDebug("participants_poll call=\(Self.shortDebugID(call.id)) attempt=\(pollAttempt) participants=\(participants.count) devices=\(participants.filter { !$0.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) peerDevice=\(peerIsReady)")
            if peerIsReady {
                return current
            }
        }
        voiceDebug("participants_timeout issue=connect_drop call=\(Self.shortDebugID(call.id)) attempts=\(maximumAttempts)")
        markActiveCallPeerWaitFailed(callID: call.id)
        await terminateRTCCallAfterPeerWaitTimeout(
            call: call,
            context: context,
            scope: scope,
            attempt: attempt
        )
        throw RTCPeerParticipantWaitError.timedOut
    }

    // JHT_MOD_BEGIN IOS_RTC_CALLKIT_AUDIO_WAIT_20260917 - 修改开始：系统接听后等 CallKit 音频会话激活，再启动本地 WebRTC 音频
    private func waitForCallKitAudioSessionBeforeVoiceStart(
        callID: String,
        scope: String,
        attempt: DirectCallAttempt?
    ) async throws {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              voiceCallSystem.hasPresentedCall(callID: normalizedCallID) else { return }
        let startedGeneration = voiceCallSystemAudioSessionGeneration
        if voiceCallSystemAudioSessionActive {
            voiceDebug("callkit_audio_wait_ready call=\(Self.shortDebugID(normalizedCallID)) gen=\(startedGeneration)")
            return
        }
        voiceDebug("callkit_audio_wait_start call=\(Self.shortDebugID(normalizedCallID)) gen=\(startedGeneration)")
        let maximumAttempts = 20
        for pollAttempt in 1...maximumAttempts {
            if let attempt {
                try ensureDirectCallAttemptIsCurrent(attempt)
            }
            guard !Task.isCancelled,
                  isCurrentRemoteScope(scope),
                  !isEndingActiveCall,
                  activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID else {
                throw CancellationError()
            }
            if voiceCallSystemAudioSessionActive {
                voiceDebug("callkit_audio_wait_ready call=\(Self.shortDebugID(normalizedCallID)) attempt=\(pollAttempt) gen=\(voiceCallSystemAudioSessionGeneration)")
                return
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                throw CancellationError()
            }
        }
        if let attempt {
            try ensureDirectCallAttemptIsCurrent(attempt)
        }
        guard !Task.isCancelled,
              isCurrentRemoteScope(scope),
              !isEndingActiveCall,
              activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID else {
            throw CancellationError()
        }
        if voiceCallSystemAudioSessionActive {
            voiceDebug("callkit_audio_wait_ready call=\(Self.shortDebugID(normalizedCallID)) attempt=final gen=\(voiceCallSystemAudioSessionGeneration)")
            return
        }
        voiceDebug("callkit_audio_wait_timeout call=\(Self.shortDebugID(normalizedCallID)) fromGen=\(startedGeneration) toGen=\(voiceCallSystemAudioSessionGeneration)")
        throw IMAPIError.server("audio session activation timeout")
    }
    // JHT_MOD_END IOS_RTC_CALLKIT_AUDIO_WAIT_20260917 - 修改结束

    private func ensureRTCParticipantWaitIsCurrent(
        callID: String,
        scope: String,
        directCallAttempt: DirectCallAttempt? = nil
    ) throws {
        if let directCallAttempt {
            try ensureDirectCallAttemptIsCurrent(directCallAttempt)
        }
        guard !Task.isCancelled,
              isCurrentRemoteScope(scope),
              !isApplicationBackgroundedForRTC,
              !isEndingActiveCall,
              activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw RTCPeerParticipantWaitError.cancelled
        }
    }

    private func markActiveCallWaitingForPeer(callID: String) {
        guard var call = activeVoiceCall,
              call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID.trimmingCharacters(in: .whitespacesAndNewlines),
              !isEndingActiveCall else { return }
        call.mediaState = .connecting
        call.statusText = "等待对方连接"
        activeVoiceCall = call
    }

    private func markActiveCallPeerWaitFailed(callID: String) {
        guard var call = activeVoiceCall,
              call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID.trimmingCharacters(in: .whitespacesAndNewlines),
              !isEndingActiveCall else { return }
        call.mediaState = .failed
        call.statusText = "连接失败"
        activeVoiceCall = call
        toast = "连接失败，请结束后重试"
    }

    private func terminateRTCCallAfterPeerWaitTimeout(
        call: RemoteRTCCall,
        context: IMAPIContext,
        scope: String,
        attempt: DirectCallAttempt? = nil
    ) async {
        if let attempt {
            guard isCurrentDirectCallAttempt(attempt) else { return }
        }
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty,
              isCurrentRemoteScope(scope),
              activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID,
              rtcPeerWaitTerminationCallIDs.insert(callID).inserted else {
            return
        }
        cancelVoiceCallWatchdog()
        stopCallMediaSession(for: activeVoiceCall, reason: "peer_participant_timeout")
        if pendingVoiceMediaJoinCallID == callID {
            pendingVoiceMediaJoinCallID = nil
        }
        releaseAudioSessionForVoiceCall()
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        let terminalReason = "peer_participant_timeout"
        let terminalAction: RTCTerminalCompensationAction =
            call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ringing"
            ? .cancel
            : .hangup
        let idempotencyKey = stableRTCTerminalMutationIdempotencyKey(
            callID: callID,
            action: terminalAction,
            reason: terminalReason,
            context: context
        )
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        do {
            let normalizedStatus = call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedStatus == "ringing" {
                try await api.cancelRTCCall(
                    context: context,
                    callID: callID,
                    reason: terminalReason,
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    idempotencyKey: idempotencyKey
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                )
            } else {
                try await api.hangupRTCCall(
                    context: context,
                    callID: callID,
                    reason: terminalReason,
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    idempotencyKey: idempotencyKey
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                )
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            clearRTCTerminalCompensationIfMatches(
                callID: callID,
                action: terminalAction,
                idempotencyKey: idempotencyKey
            )
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
            // Keep the failed call surface visible. The authoritative server resource
            // is ended exactly once above, while the user still receives a stable
            // failure state and may dismiss/retry without a disappearing screen.
            guard isCurrentRemoteScope(scope),
                  activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
                return
            }
            markActiveCallPeerWaitFailed(callID: callID)
        } catch {
            guard isCurrentRemoteScope(scope),
                  attempt.map(isCurrentDirectCallAttempt) ?? true,
                  activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
                return
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            enqueueRTCTerminalCompensationAfterInitialFailure(
                callID: callID,
                action: terminalAction,
                reason: terminalReason,
                context: context,
                idempotencyKey: idempotencyKey,
                error: error
            )
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
            toast = "连接失败，结束通话失败，请重试"
        }
    }

    private func normalizedJoinedRoom(
        _ joinedRoom: RemoteRTCRoomJoinData,
        call: RemoteRTCCall,
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        participants extraParticipants: [RemoteRTCRoomParticipant] = []
    ) -> RemoteRTCRoomJoinData {
        let normalizedRoomID = joinedRoom.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? roomID : joinedRoom.roomID
        let normalizedToken = joinedRoom.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rtcToken : joinedRoom.rtcToken
        let selfUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? currentUser.id
        let selfDeviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        var participants = joinedRoom.participants
        for participant in extraParticipants {
            if !participants.contains(where: { $0.uid == participant.uid && $0.deviceID == participant.deviceID }) {
                participants.append(participant)
            }
        }
        let selfParticipant = joinedRoom.selfParticipant
            ?? participants.first { participant in
                let uid = participant.uid.trimmingCharacters(in: .whitespacesAndNewlines)
                let deviceID = participant.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
                return (!selfUID.isEmpty && uid == selfUID) || (!selfDeviceID.isEmpty && deviceID == selfDeviceID)
            }
            ?? RemoteRTCRoomParticipant(uid: selfUID, deviceID: selfDeviceID, deviceType: "ios", role: "self")
        if !participants.contains(where: { $0.uid == selfParticipant.uid && $0.deviceID == selfParticipant.deviceID }) {
            participants.append(selfParticipant)
        }
        let peerParticipant = resolvedRTCPeerParticipant(
            explicitPeer: joinedRoom.peerParticipant,
            call: call,
            selfParticipant: selfParticipant,
            participants: participants
        )
        if let peerParticipant,
           !participants.contains(where: { $0.uid == peerParticipant.uid && $0.deviceID == peerParticipant.deviceID }) {
            participants.append(peerParticipant)
        }
        return RemoteRTCRoomJoinData(
            roomID: normalizedRoomID,
            rtcToken: normalizedToken,
            media: joinedRoom.media,
            selfParticipant: selfParticipant,
            peerParticipant: peerParticipant,
            participants: participants
        )
    }

    private func rtcCall(_ call: RemoteRTCCall, withRTCToken rtcToken: String) -> RemoteRTCCall {
        RemoteRTCCall(
            id: call.id,
            status: call.status,
            roomID: call.roomID,
            rtcToken: rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? call.rtcToken : rtcToken,
            callerUID: call.callerUID,
            calleeUID: call.calleeUID,
            channelID: call.channelID,
            channelType: call.channelType,
            callType: call.callType,
            requestedMediaMode: call.requestedMediaMode,
            mediaMode: call.mediaMode,
            peerCapabilityStatus: call.peerCapabilityStatus,
            callerCapabilities: call.callerCapabilities,
            callerDevice: call.callerDevice,
            calleeDevice: call.calleeDevice,
            acceptedDevice: call.acceptedDevice,
            callerProfile: call.callerProfile,
            calleeProfile: call.calleeProfile,
            callerName: call.callerName,
            calleeName: call.calleeName,
            callerAvatarURL: call.callerAvatarURL,
            callerAvatarVersion: call.callerAvatarVersion,
            callerAvatarUpdatedAt: call.callerAvatarUpdatedAt,
            calleeAvatarURL: call.calleeAvatarURL,
            calleeAvatarVersion: call.calleeAvatarVersion,
            calleeAvatarUpdatedAt: call.calleeAvatarUpdatedAt,
            createdAt: call.createdAt,
            updatedAt: call.updatedAt,
            startedAt: call.startedAt,
            acceptedAt: call.acceptedAt,
            endedAt: call.endedAt,
            endReason: call.endReason,
            stateVersion: call.stateVersion
        )
    }

    private func voiceMediaPeerParticipant(call: RemoteRTCCall, joinedRoom: RemoteRTCRoomJoinData) -> RemoteRTCRoomParticipant? {
        rtcPeerParticipantResolution(call: call, joinedRoom: joinedRoom)?.participant
    }

    private func joinedRoomPeerParticipant(call: RemoteRTCCall, joinedRoom: RemoteRTCRoomJoinData) -> RemoteRTCRoomParticipant? {
        rtcPeerParticipantResolution(call: call, joinedRoom: joinedRoom)?.participant
    }

    private func rtcPeerParticipantResolution(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData
    ) -> RTCResolvedPeerParticipant? {
        RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: currentUserIdentitySet().union([
                joinedRoom.selfParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ].filter { !$0.isEmpty }),
            selfParticipant: joinedRoom.selfParticipant,
            explicitPeer: joinedRoom.peerParticipant,
            participants: joinedRoom.participants,
            directionHint: rtcPeerDirectionHint(callID: call.id)
        )
    }

    private func resolvedRTCPeerParticipant(
        explicitPeer: RemoteRTCRoomParticipant?,
        call: RemoteRTCCall,
        selfParticipant: RemoteRTCRoomParticipant?,
        participants: [RemoteRTCRoomParticipant]
    ) -> RemoteRTCRoomParticipant? {
        RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: currentUserIdentitySet().union([
                selfParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ].filter { !$0.isEmpty }),
            selfParticipant: selfParticipant,
            explicitPeer: explicitPeer,
            participants: participants,
            directionHint: rtcPeerDirectionHint(callID: call.id)
        )?.participant
    }

    private func rtcPeerDirectionHint(callID: String) -> CallLifecycleDirection? {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              let activeVoiceCall,
              activeVoiceCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID else {
            return nil
        }
        switch activeVoiceCall.direction {
        case "呼出":
            return .outgoing
        case "来电":
            return .incoming
        default:
            return nil
        }
    }

#if DEBUG
    func waitForRTCPeerParticipantForTesting(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData,
        policy: RTCPeerParticipantWaitPolicy
    ) async throws -> RemoteRTCRoomJoinData {
        try await joinedRoomReadyForVoiceStart(
            call: call,
            joinedRoom: joinedRoom,
            context: apiContext,
            roomID: call.roomID,
            rtcToken: call.rtcToken,
            scope: remoteDataScopeKey(for: apiContext),
            policy: policy
        )
    }
#endif

    func voiceDebug(_ message: @autoclosure () -> String) {
        let value = message()
#if DEBUG
        NSLog("[JHT RTC][AppState] %@", value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(
                category: "AppState",
                media: rtcDiagnosticMediaLabel(for: value),
                message: value
            )
        }
    }

    // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: lifecycle-only diagnostics for lock/unlock RTC interface tracing.
    func logRTCLifecycleInterfaceEvent(_ event: String) {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeCallID = activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let incomingCallID = incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heartbeatCallID = rtcMediaHeartbeatSession?.callID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heartbeatState = rtcMediaHeartbeatSession?.desiredMediaState ?? "none"
        let lastReportedState = rtcMediaHeartbeatSession?.lastReportedMediaState ?? "none"
        voiceDebug(
            "app_lifecycle interface=rtc event=\(normalizedEvent.isEmpty ? "unknown" : normalizedEvent) backgrounded=\(isApplicationBackgroundedForRTC) active=\(Self.shortDebugID(activeCallID)) incoming=\(Self.shortDebugID(incomingCallID)) heartbeat=\(Self.shortDebugID(heartbeatCallID)) desired=\(heartbeatState) last=\(lastReportedState) ending=\(isEndingActiveCall)"
        )
    }
    // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END

    private func rtcDiagnosticMediaLabel(for message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("video") || normalized.contains("media=video") || normalized.contains("media_mode=video") {
            return "video"
        }
        if normalized.contains("voice") || normalized.contains("media=audio") || normalized.contains("media_mode=audio") {
            return "voice"
        }
        if let call = activeVoiceCall {
            return call.isVideoCall || call.mediaMode == "video" || call.requestedMediaMode == "video" ? "video" : "voice"
        }
        if let incoming = incomingVoiceCall {
            return incoming.isVideo ? "video" : "voice"
        }
        return "unknown"
    }

    static func shortDebugID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return String(trimmed.suffix(6))
    }

    static func rtcDebugContextSummary(_ context: IMAPIContext) -> String {
        let appID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "uid=\(shortDebugID(context.imUID ?? ""))",
            "app=\(appID.isEmpty ? "empty" : appID)",
            "device=\(shortDebugID(context.deviceID))",
            "tenant=\(shortDebugID(context.tenantID ?? ""))",
            "imSession=\(context.hasIMSession)"
        ].joined(separator: " ")
    }

    private static func rtcStatusCountsSummary(_ statuses: [String]) -> String {
        let counts = statuses.reduce(into: [String: Int]()) { partial, rawStatus in
            let key = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            partial[key.isEmpty ? "empty" : key, default: 0] += 1
        }
        guard !counts.isEmpty else { return "none" }
        return counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
    }

    private static func rtcIdentitySummary(_ identities: Set<String>) -> String {
        let items = identities.map { shortDebugID($0) }.sorted()
        return items.isEmpty ? "none" : items.joined(separator: "|")
    }

    private static func voiceJoinSummary(callID: String, joinedRoom: RemoteRTCRoomJoinData) -> String {
        let selfDevice = joinedRoom.selfParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let peerDevice = joinedRoom.peerParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let selfID = joinedRoom.selfParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let peerID = joinedRoom.peerParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let participantDeviceCount = joinedRoom.participants.filter {
            !$0.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return "join_ok call=\(shortDebugID(callID)) room=\(!joinedRoom.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) token=\(!joinedRoom.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) selfID=\(selfID) selfDevice=\(selfDevice) peerID=\(peerID) peerDevice=\(peerDevice) participants=\(joinedRoom.participants.count) participantDevices=\(participantDeviceCount) ice=\(joinedRoom.media.iceServers.count)"
    }

    static func safeVoiceErrorSummary(_ error: Error) -> String {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case let .missingContext(message):
                return "missing_context:\(message)"
            case let .badURL(message):
                return "bad_url:\(message)"
            case let .unauthorized(message):
                return "unauthorized:\(message)"
            case let .forbidden(message):
                return "forbidden:\(message)"
            case let .businessForbidden(code, _, _):
                return "business_forbidden:\(code)"
            case let .conflict(code, _):
                return "conflict:\(code)"
            case let .server(message):
                return "server:\(message)"
            case let .httpStatus(statusCode, message):
                return "http_status:\(statusCode):\(message)"
            case .securityBlocked:
                return "security_blocked"
            case let .forcedAuthRequired(requirement):
                return "forced_auth_required:\(requirement.rawValue)"
            case let .loginSecurity(code, _, _):
                return "login_security:\(code)"
            case let .rateLimited(code, _, _, _):
                return "rate_limited:\(code)"
            case .emptyResponse:
                return "empty_response"
            }
        }
        if error is CancellationError {
            return "cancelled"
        }
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：保留安全的 NSError 定位字段，不记录 userInfo/token
        let nsError = error as NSError
        var parts = [
            "type=\(String(describing: type(of: error)))",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlyingDomain=\(underlying.domain)")
            parts.append("underlyingCode=\(underlying.code)")
        }
        return parts.joined(separator: " ")
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    }

    private func stopVoiceMediaSession(reason: String) {
        voiceMediaEventTask?.cancel()
        voiceMediaEventTask = nil
        activeVoiceMediaCallID = nil
        pendingVoiceMediaJoinCallID = nil
        Task { [voiceMediaClient] in
            await voiceMediaClient.stop(reason: reason)
        }
    }

    private func startRTCMediaStateHeartbeat(
        callID: String,
        roomID: String,
        rtcToken: String,
        joinedRoom: RemoteRTCRoomJoinData,
        scope: String,
        attempt: DirectCallAttempt? = nil
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              !normalizedRoomID.isEmpty,
              !normalizedToken.isEmpty,
              activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID,
              !isEndingActiveCall,
              isCurrentRemoteScope(scope),
              attempt.map(isCurrentDirectCallAttempt) ?? true else {
            return
        }
        if var current = rtcMediaHeartbeatSession,
           current.callID == normalizedCallID,
           current.scope == scope,
           current.operationID == attempt?.operationID,
           isRTCMediaHeartbeatCurrent(current) {
            current.context = apiContext
            current.roomID = normalizedRoomID
            current.rtcToken = normalizedToken
            current.selfParticipant = joinedRoom.selfParticipant ?? current.selfParticipant
            current.desiredMediaState = rtcMediaStateForHeartbeat(activeVoiceCall)
            current.connectedReportPending = current.connectedReportPending
                || (current.desiredMediaState == "connected" && !current.hasReportedConnected)
            rtcMediaHeartbeatSession = current
            renewRTCMediaStateHeartbeatNow(reason: "media_refreshed")
            return
        }
        stopRTCMediaStateHeartbeat(reason: "restart")
        rtcMediaHeartbeatGeneration &+= 1
        let now = rtcMediaHeartbeatNow()
        rtcMediaHeartbeatSession = RTCMediaHeartbeatSession(
            generation: rtcMediaHeartbeatGeneration,
            callID: normalizedCallID,
            scope: scope,
            context: apiContext,
            roomID: normalizedRoomID,
            rtcToken: normalizedToken,
            selfParticipant: joinedRoom.selfParticipant,
            desiredMediaState: rtcMediaStateForHeartbeat(activeVoiceCall),
            lastReportedMediaState: nil,
            startedAt: now,
            lastAuthoritativeSuccessAt: now
        )
        let initiallyConnected = rtcMediaHeartbeatSession?.desiredMediaState == "connected"
        rtcMediaHeartbeatSession?.connectedReportPending = initiallyConnected
        rtcMediaHeartbeatSession?.operationID = attempt?.operationID
        renewRTCMediaStateHeartbeatNow(reason: "media_started")
    }

    func stopRTCMediaStateHeartbeat(reason: String) {
        rtcQualityReportingSession?.finish()
        rtcQualityReportingSession = nil
        let hadSession = rtcMediaHeartbeatSession != nil
        rtcMediaHeartbeatGeneration &+= 1
        rtcMediaHeartbeatTimerTask?.cancel()
        rtcMediaHeartbeatTimerTask = nil
        rtcMediaHeartbeatRenewalTask?.cancel()
        rtcMediaHeartbeatRenewalTask = nil
        rtcMediaHeartbeatRenewalGeneration = nil
        rtcMediaHeartbeatPendingImmediateRenewal = false
        rtcMediaHeartbeatSession = nil
        if hadSession {
            voiceDebug("media_heartbeat_stop reason=\(reason)")
        }
    }

    func reconcileRTCMediaStateHeartbeatContextChange(
        from oldContext: IMAPIContext,
        to newContext: IMAPIContext
    ) {
        guard var session = rtcMediaHeartbeatSession else { return }
        let oldScope = remoteDataScopeKey(for: oldContext)
        let newScope = remoteDataScopeKey(for: newContext)
        guard oldScope == session.scope,
              newScope == session.scope,
              oldContext.deviceID == newContext.deviceID,
              oldContext.appID == newContext.appID,
              oldContext.accountID == newContext.accountID,
              oldContext.sessionEpoch == newContext.sessionEpoch,
              newContext.hasIMSession else {
            stopRTCMediaStateHeartbeat(reason: "scope_changed")
            return
        }
        session.context = newContext
        rtcMediaHeartbeatSession = session
        renewRTCMediaStateHeartbeatNow(reason: "session_refreshed")
    }

    private func rtcMediaStateForHeartbeat(_ call: VoiceCallSession?) -> String {
        guard let call else { return "connecting" }
        if call.isRecoveringNetwork || call.mediaState == .unstable {
            return "reconnecting"
        }
        if !call.isVideoCall || activeVoiceMediaCallID == call.callID {
            // JHT_MOD_BEGIN RTC_VOICE_TRANSPORT_CONNECTED_TIMER_20260914 - 修改开始：对齐 Android，语音计时/心跳以 ICE/PeerConnection 连通为准；远端音轨/RTP 保留为质量诊断信号
            if call.voiceTransportConnected {
                return "connected"
            }
            // JHT_MOD_END RTC_VOICE_TRANSPORT_CONNECTED_TIMER_20260914 - 修改结束
            return call.connectedAt == nil ? "connecting" : "reconnecting"
        }
        if call.connectedAt != nil || call.mediaState == .connected {
            return "connected"
        }
        return "connecting"
    }

    private func updateRTCMediaStateHeartbeat(_ mediaState: String, force: Bool = false) {
        let normalized = mediaState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["connecting", "connected", "reconnecting"].contains(normalized),
              var session = rtcMediaHeartbeatSession,
              isRTCMediaHeartbeatCurrent(session) else {
            return
        }
        let didChange = session.desiredMediaState != normalized
        session.desiredMediaState = normalized
        if normalized == "connected", !session.hasReportedConnected {
            session.connectedReportPending = true
        }
        rtcMediaHeartbeatSession = session
        if force || didChange || session.lastReportedMediaState != normalized {
            renewRTCMediaStateHeartbeatNow(reason: didChange ? "media_state_changed" : "forced")
        }
    }

    func resumeRTCMediaStateHeartbeatAfterForeground() {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        renewRTCMediaStateHeartbeatNow(reason: "foreground")
    }

    private func renewRTCMediaStateHeartbeatNow(reason: String) {
        guard let session = rtcMediaHeartbeatSession,
              isRTCMediaHeartbeatCurrent(session) else {
            stopRTCMediaStateHeartbeat(reason: "not_current")
            return
        }
        rtcMediaHeartbeatTimerTask?.cancel()
        rtcMediaHeartbeatTimerTask = nil
        if rtcMediaHeartbeatRenewalTask != nil {
            rtcMediaHeartbeatPendingImmediateRenewal = true
            return
        }
        let generation = session.generation
        rtcMediaHeartbeatRenewalGeneration = generation
        rtcMediaHeartbeatRenewalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRTCMediaStateHeartbeatRenewal(generation: generation, reason: reason)
            guard self.rtcMediaHeartbeatRenewalGeneration == generation else { return }
            self.rtcMediaHeartbeatRenewalTask = nil
            self.rtcMediaHeartbeatRenewalGeneration = nil
            guard let current = self.rtcMediaHeartbeatSession,
                  current.generation == generation,
                  self.isRTCMediaHeartbeatCurrent(current) else {
                return
            }
            if self.rtcMediaHeartbeatPendingImmediateRenewal {
                self.rtcMediaHeartbeatPendingImmediateRenewal = false
                self.renewRTCMediaStateHeartbeatNow(reason: "pending")
            } else {
                self.scheduleNextRTCMediaStateHeartbeat(generation: generation)
            }
        }
    }

    private func scheduleNextRTCMediaStateHeartbeat(generation: UInt64) {
        rtcMediaHeartbeatTimerTask?.cancel()
        rtcMediaHeartbeatTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.rtcMediaHeartbeatSleep(self.rtcMediaHeartbeatIntervalNanoseconds)
            } catch {
                return
            }
            guard let session = self.rtcMediaHeartbeatSession,
                  session.generation == generation,
                  self.isRTCMediaHeartbeatCurrent(session) else {
                return
            }
            self.rtcMediaHeartbeatTimerTask = nil
            self.renewRTCMediaStateHeartbeatNow(reason: "timer")
        }
    }

    private func performRTCMediaStateHeartbeatRenewal(generation: UInt64, reason: String) async {
        do {
            let result = try await updateRTCMediaStateWithConflictRetry(
                generation: generation,
                reason: reason
            )
            applyRTCMediaHeartbeatSuccess(
                updatedCall: result.call,
                reportedMediaState: result.reportedMediaState,
                generation: generation,
                reason: reason
            )
        } catch {
            guard let current = rtcMediaHeartbeatSession,
                  current.generation == generation,
                  isRTCMediaHeartbeatCurrent(current) else {
                return
            }
            if RTCMediaStateHeartbeatFailurePolicy.needsParticipantRejoin(error) {
                await recoverRTCMediaHeartbeatParticipantLease(generation: generation, reason: reason)
                return
            }
            handleRTCMediaHeartbeatFailure(error, generation: generation)
        }
    }

    private func updateRTCMediaStateWithConflictRetry(
        generation: UInt64,
        reason: String
    ) async throws -> (call: RemoteRTCCall, reportedMediaState: String) {
        var conflictRetryAttempt = 0
        while true {
            guard let snapshot = rtcMediaHeartbeatSession,
                  snapshot.generation == generation,
                  isRTCMediaHeartbeatCurrent(snapshot) else {
                throw CancellationError()
            }
            do {
                // Preserve the first proven connection even if a reconnect event
                // arrives while the previous request is still in flight.
                let reportedState = snapshot.connectedReportPending ? "connected" : snapshot.desiredMediaState
                // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log RTC request attempts around lock/unlock without changing request payload.
                voiceDebug(
                    "request_interface path=/api/rtc/calls/{id}/media-state call=\(Self.shortDebugID(snapshot.callID)) state=\(reportedState) reason=\(reason) backgrounded=\(isApplicationBackgroundedForRTC)"
                )
                // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
                let updatedCall = try await api.updateRTCMediaState(
                    context: snapshot.context,
                    callID: snapshot.callID,
                    mediaState: reportedState,
                    expectedStateVersion: nil,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                return (updatedCall, reportedState)
            } catch {
                guard RTCMediaStateHeartbeatFailurePolicy.isStateVersionConflict(error),
                      conflictRetryAttempt < RTCMediaStateHeartbeatFailurePolicy.stateVersionConflictRetryLimit else {
                    throw error
                }
                conflictRetryAttempt += 1
                let delay = RTCMediaStateHeartbeatFailurePolicy.stateVersionConflictRetryDelayNanoseconds(
                    attempt: conflictRetryAttempt,
                    callID: snapshot.callID
                )
                try await Task.sleep(nanoseconds: delay)
                guard let current = rtcMediaHeartbeatSession,
                      current.generation == generation,
                      isRTCMediaHeartbeatCurrent(current) else {
                    throw CancellationError()
                }
            }
        }
    }

    private func recoverRTCMediaHeartbeatParticipantLease(generation: UInt64, reason: String) async {
        guard let snapshot = rtcMediaHeartbeatSession,
              snapshot.generation == generation,
              isRTCMediaHeartbeatCurrent(snapshot) else {
            return
        }
        do {
            let joined = try await api.joinRTCRoom(
                context: snapshot.context,
                roomID: snapshot.roomID,
                rtcToken: snapshot.rtcToken
            )
            guard var current = rtcMediaHeartbeatSession,
                  current.generation == generation,
                  isRTCMediaHeartbeatCurrent(current) else {
                return
            }
            let refreshedToken = joined.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !refreshedToken.isEmpty {
                current.rtcToken = refreshedToken
                if activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == current.callID {
                    activeVoiceCall?.rtcToken = refreshedToken
                }
            }
            current.selfParticipant = joined.selfParticipant ?? current.selfParticipant
            rtcMediaHeartbeatSession = current

            let result = try await updateRTCMediaStateWithConflictRetry(
                generation: generation,
                reason: "\(reason)_rejoined"
            )
            applyRTCMediaHeartbeatSuccess(
                updatedCall: result.call,
                reportedMediaState: result.reportedMediaState,
                generation: generation,
                reason: "\(reason)_rejoined"
            )
        } catch {
            guard let current = rtcMediaHeartbeatSession,
                  current.generation == generation,
                  isRTCMediaHeartbeatCurrent(current) else {
                return
            }
            handleRTCMediaHeartbeatFailure(error, generation: generation)
        }
    }

    private func applyRTCMediaHeartbeatSuccess(
        updatedCall: RemoteRTCCall,
        reportedMediaState: String,
        generation: UInt64,
        reason: String
    ) {
        guard var session = rtcMediaHeartbeatSession,
              session.generation == generation,
              isRTCMediaHeartbeatCurrent(session) else {
            return
        }
        session.lastReportedMediaState = reportedMediaState
        if reportedMediaState == "connected" {
            session.hasReportedConnected = true
            session.connectedReportPending = false
        }
        session.lastAuthoritativeSuccessAt = rtcMediaHeartbeatNow()
        rtcMediaHeartbeatSession = session
        if session.desiredMediaState != reportedMediaState {
            rtcMediaHeartbeatPendingImmediateRenewal = true
        }
        if activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == session.callID,
           updatedCall.stateVersion > 0 {
            activeVoiceCall?.stateVersion = max(activeVoiceCall?.stateVersion ?? 0, updatedCall.stateVersion)
        }
        voiceDebug(
            "media_heartbeat_ok call=\(Self.shortDebugID(session.callID)) state=\(reportedMediaState) reason=\(reason)"
        )
    }

    private func handleRTCMediaHeartbeatFailure(_ error: Error, generation: UInt64) {
        guard let session = rtcMediaHeartbeatSession,
              session.generation == generation,
              isRTCMediaHeartbeatCurrent(session) else {
            return
        }
        if RTCMediaStateHeartbeatFailurePolicy.shouldFinishLocalCall(
            after: error,
            lastAuthoritativeSuccessAt: session.lastAuthoritativeSuccessAt,
            now: rtcMediaHeartbeatNow()
        ) {
            let stateVersion = activeVoiceCall?.stateVersion ?? 0
            let callKind = activeVoiceCall?.isVideoCall == true ? "视频" : "语音"
            voiceDebug(
                "media_heartbeat_terminal issue=media_degrade_or_long_call_end call=\(Self.shortDebugID(session.callID)) error=\(Self.safeVoiceErrorSummary(error))"
            )
            stopRTCMediaStateHeartbeat(reason: "authoritative_terminal")
            finishVoiceCallFromRemote(
                status: "已结束",
                subtitle: "\(callKind)通话 · 通话已结束",
                toastText: "\(callKind)通话已结束",
                endReason: "server_heartbeat_terminal",
                stateVersion: stateVersion,
                expectedCallID: session.callID,
                lifecyclePhase: .ended
            )
            return
        }
        voiceDebug(
            "media_heartbeat_failed issue=media_degrade_or_long_call_end call=\(Self.shortDebugID(session.callID)) error=\(Self.safeVoiceErrorSummary(error))"
        )
    }

    private func isRTCMediaHeartbeatCurrent(_ session: RTCMediaHeartbeatSession) -> Bool {
        guard !Task.isCancelled,
              isAuthenticated,
              (!isEndingActiveCall || session.isFinishing),
              isCurrentRemoteScope(session.scope),
              session.context.deviceID == apiContext.deviceID,
              session.context.appID == apiContext.appID,
              session.context.accountID == apiContext.accountID,
              session.context.sessionEpoch == apiContext.sessionEpoch,
              session.operationID == nil || directCallResourceOwners[session.callID]?.operationID == session.operationID,
              let activeCall = activeVoiceCall,
              activeCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == session.callID else {
            return false
        }
        return session.generation == rtcMediaHeartbeatGeneration
    }

#if DEBUG
    func startRTCMediaStateHeartbeatForTesting(
        callID: String,
        roomID: String,
        rtcToken: String,
        joinedRoom: RemoteRTCRoomJoinData
    ) {
        startRTCMediaStateHeartbeat(
            callID: callID,
            roomID: roomID,
            rtcToken: rtcToken,
            joinedRoom: joinedRoom,
            scope: remoteDataScopeKey(for: apiContext)
        )
    }

    func updateRTCMediaHeartbeatContextForTesting(_ update: (inout IMAPIContext) -> Void) {
        var context = apiContext
        update(&context)
        apiContext = context
    }

    func renewRTCMediaStateHeartbeatForTesting() {
        renewRTCMediaStateHeartbeatNow(reason: "test")
    }

    func resumeRTCMediaStateHeartbeatAfterForegroundForTesting() {
        resumeRTCMediaStateHeartbeatAfterForeground()
    }

    func stopRTCMediaStateHeartbeatForTesting() {
        stopRTCMediaStateHeartbeat(reason: "test")
    }

    var rtcMediaHeartbeatSnapshotForTesting: RTCMediaHeartbeatSession? {
        rtcMediaHeartbeatSession
    }

    var rtcMediaHeartbeatTimerArmedForTesting: Bool {
        rtcMediaHeartbeatTimerTask != nil
    }
#endif

    private func startVideoMediaSession(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData,
        direction: String,
        peer: IMUser,
        cameraEnabled: Bool,
        scope: String,
        attempt: DirectCallAttempt? = nil
    ) {
        if let attempt {
            guard isCurrentDirectCallAttempt(attempt),
                  directCallResourceIsOwned(callID: call.id, by: attempt) else { return }
        }
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty, activeVideoMediaCallID != callID else { return }
        stoppedVideoMediaCallIDs.remove(callID)
        let roomID = call.roomID.isEmpty ? joinedRoom.roomID : call.roomID
        let rtcToken = joinedRoom.rtcToken.isEmpty ? call.rtcToken : joinedRoom.rtcToken
        let joinedLocalDeviceID = joinedRoom.selfParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localDeviceID = joinedLocalDeviceID.isEmpty ? apiContext.deviceID : joinedLocalDeviceID
        let peerParticipant = voiceMediaPeerParticipant(call: call, joinedRoom: joinedRoom)
        let participantDeviceID = peerParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let peerDeviceID = participantDeviceID
        guard !roomID.isEmpty, !rtcToken.isEmpty, !localDeviceID.isEmpty, !peerDeviceID.isEmpty else {
            toast = "视频设备信息不完整，请稍后重试"
            return
        }
        activeVideoMediaCallID = callID
        startRTCMediaStateHeartbeat(
            callID: callID,
            roomID: roomID,
            rtcToken: rtcToken,
            joinedRoom: joinedRoom,
            scope: scope,
            attempt: attempt
        )
        let mediaGeneration = rtcMediaHeartbeatGeneration
        let qualitySession = RTCQualityReportingSession(
            context: apiContext, scope: scope, callID: callID, roomID: roomID,
            direction: direction, mediaMode: activeVoiceCall?.mediaMode ?? "video",
            generation: mediaGeneration, rtcToken: rtcToken
        )
        rtcQualityReportingSession?.finish()
        rtcQualityReportingSession = qualitySession
        AccessDiagnostics.shared.recordTurnServers(urls: joinedRoom.media.iceServers.flatMap(\.urls), callID: callID)
        let mediaContext = VideoMediaSessionContext(
            callID: callID,
            roomID: roomID,
            rtcToken: rtcToken,
            direction: direction,
            localUID: joinedRoom.selfParticipant?.uid ?? (apiContext.imUID ?? currentUser.id),
            localDeviceID: localDeviceID,
            peerUID: peerParticipant?.uid ?? peer.id,
            peerDeviceID: peerDeviceID,
            iceServers: joinedRoom.media.iceServers,
            iceCredentialExpiresAt: joinedRoom.media.iceCredentialExpiresAt,
            iceCredentialRefreshAfter: joinedRoom.media.iceCredentialRefreshAfter,
            turnRouteTelemetry: joinedRoom.media.turnRouteTelemetry,
            icePolicy: joinedRoom.media.icePolicy ?? .legacy,
            postSignal: { [weak self] envelope, activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                return try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.postRTCSignalV2(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken,
                        envelope: envelope
                    )
                }
            },
            pollSignals: { [weak self] cursor, activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                return try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.pollRTCSignalsV2(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken,
                        cursor: cursor,
                        limit: 100,
                        waitMS: 25_000
                    )
                }
            },
            acknowledgeSignals: { [weak self] cursor, activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.ackRTCSignals(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken,
                        cursor: cursor
                    )
                }
            },
            refreshIceCredentials: { [weak self] activeRTCToken in
                guard let self,
                      self.isCurrentRemoteScope(scope) else {
                    throw CancellationError()
                }
                let refreshed = try await self.awaitRTCMediaStage(generation: mediaGeneration) { signalContext in
                    try await self.api.refreshRTCIceCredentials(
                        context: signalContext,
                        roomID: roomID,
                        rtcToken: activeRTCToken
                    )
                }
                qualitySession.acceptRefreshedToken(refreshed.rtcToken)
                AccessDiagnostics.shared.recordTurnServers(urls: refreshed.iceServers.flatMap(\.urls), callID: callID)
                return refreshed
            },
            reportQuality: { [weak self] samples, activeRTCToken in
                guard let self else {
                    throw CancellationError()
                }
                let context = try self.currentRTCQualityRequestContext(qualitySession, rtcToken: activeRTCToken)
                _ = try await self.api.postRTCQualitySamples(
                    context: context,
                    roomID: qualitySession.roomID,
                    rtcToken: activeRTCToken,
                    samples: samples
                )
                _ = try self.currentRTCQualityRequestContext(qualitySession, rtcToken: activeRTCToken)
            }
        )
        videoMediaEventTask?.cancel()
        videoMediaEventTask = Task { [weak self, videoMediaClient] in
            guard let self else { return }
            do {
                // Adopt preview capture only after its queued preparation/stop
                // completes. An older preview must not stop the new session.
                await self.videoPreviewMediaTask?.value
                guard !Task.isCancelled,
                      self.activeVideoMediaCallID == callID,
                      self.isCurrentRemoteScope(scope),
                      attempt.map(self.isCurrentDirectCallAttempt) ?? true else { return }
                self.videoPreviewMediaOwnerID = nil
                let events = try await self.awaitDirectCallStage(attempt) {
                    try await videoMediaClient.start(
                        context: mediaContext,
                        cameraEnabled: cameraEnabled
                    )
                }
                let speakerOn = self.activeVoiceCall?.speakerOn ?? true
                try? await videoMediaClient.setSpeakerEnabled(speakerOn)
                for await event in events {
                    guard !Task.isCancelled else { break }
                    guard attempt.map({ self.isCurrentDirectCallAttempt($0) || self.isCurrentRTCMediaOperation($0.operationID) }) ?? true else {
                        break
                    }
                    self.handleVideoMediaEvent(
                        event,
                        callID: callID,
                        scope: scope,
                        operationID: attempt?.operationID
                    )
                }
            } catch {
                guard attempt.map(self.isCurrentDirectCallAttempt) ?? true else {
                    return
                }
                // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：视频本地媒体启动失败保留安全错误摘要
                self.voiceDebug("video_client_start_failed stage=media_start call=\(Self.shortDebugID(callID)) error=\(Self.safeVoiceErrorSummary(error))")
                // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
                self.handleVideoMediaEvent(
                    .failed,
                    callID: callID,
                    scope: scope,
                    operationID: attempt?.operationID
                )
            }
        }
    }

    func handleVideoMediaEvent(
        _ event: RTCVideoMediaEvent,
        callID: String? = nil,
        scope: String? = nil,
        operationID: UUID? = nil,
        now: Date = Date()
    ) {
        guard !isEndingActiveCall else { return }
        if let scope, !isCurrentRemoteScope(scope) { return }
        if let operationID,
           currentDirectCallAttempt(for: .video)?.operationID != operationID,
           !isCurrentRTCMediaOperation(operationID) {
            return
        }
        guard var call = activeVoiceCall, call.isVideoCall else { return }
        if let callID, !callID.isEmpty, call.callID != callID { return }
        if call.videoConnectionGate.apply(event), call.connectedAt == nil {
            call.connectedAt = now
            call.mediaState = .connected
            call.statusText = "通话中"
            call.isRecoveringNetwork = false
            cancelVoiceCallWatchdog()
            if let currentCallID = call.callID {
                _ = advanceCallLifecycle(callID: currentCallID, to: .connected, reason: "video_media_connected")
            }
        }
        switch event {
        case .remoteAudioTrackReady:
            break
        case .remoteVideoTrackReady:
            call.remoteVideoTrackReady = true
        case .signaling, .connecting:
            if call.connectedAt == nil { call.statusText = "连接中" }
        case .reconnecting:
            call.isRecoveringNetwork = true
            call.statusText = "网络不稳定，正在恢复"
            if let currentCallID = call.callID {
                _ = advanceCallLifecycle(callID: currentCallID, to: .reconnecting, reason: "video_media_reconnecting")
            }
        case .connectionRecovered:
            call.isRecoveringNetwork = false
            call.statusText = call.connectedAt == nil ? "连接中" : "通话中"
            if call.connectedAt != nil, let currentCallID = call.callID {
                _ = advanceCallLifecycle(callID: currentCallID, to: .connected, reason: "video_media_recovered")
            }
        case .cameraPaused:
            call.localCameraEnabled = false
        case .cameraUnavailable:
            call.localCameraEnabled = false
            toast = "摄像头暂不可用，已关闭摄像头继续视频通话"
        case .cameraResumed:
            call.localCameraEnabled = true
        case .remoteCameraPaused:
            call.remoteCameraEnabled = false
            call.remoteVideoTrackReady = false
        case .remoteCameraResumed:
            call.remoteCameraEnabled = true
            call.remoteVideoTrackReady = false
        case .remoteDowngradedToAudio:
            applyVideoAudioDowngrade(to: &call)
        case .serverSignalTerminal:
            call.mediaState = .closed
            call.statusText = "通话已结束"
            call.endedReason = "server_signal_terminal"
            activeVoiceCall = call
            finishVoiceCallFromRemote(
                status: "已结束",
                subtitle: "视频通话 · 通话已结束",
                toastText: "视频通话已结束",
                endReason: "server_signal_terminal",
                stateVersion: call.stateVersion,
                mediaAlreadyStopped: true,
                expectedCallID: call.callID,
                lifecyclePhase: .ended
            )
            return
        case .failed:
            let failedCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let requestContext = apiContext
            call.mediaState = .failed
            call.statusText = "通话连接失败"
            call.endedReason = "media_failed"
            activeVoiceCall = call
            finishVoiceCallFromRemote(
                status: "连接失败",
                subtitle: "视频通话 · 媒体连接失败",
                toastText: "视频通话连接失败",
                endReason: "media_failed",
                stateVersion: call.stateVersion,
                expectedCallID: call.callID,
                lifecyclePhase: .failure
            )
            if !failedCallID.isEmpty, requestContext.hasIMSession {
                enqueueRTCTerminalCompensation(
                    callID: failedCallID,
                    action: .hangup,
                    reason: "media_failed",
                    context: requestContext
                )
            }
            return
        case .closed:
            activeVoiceCall = call
            finishVoiceCallFromRemote(status: "已结束", subtitle: "视频通话 · 通话已结束", toastText: "视频通话已结束", expectedCallID: call.callID, lifecyclePhase: .ended)
            return
        default:
            break
        }
        activeVoiceCall = call
        if event != .failed {
            updateRTCMediaStateHeartbeat(rtcMediaStateForHeartbeat(call))
        }
    }

    func toggleActiveVideoCamera() {
        guard let call = activeVoiceCall, call.mediaMode == "video" else { return }
        let callID = call.callID ?? ""
        let previous = call.localCameraEnabled
        let desired = !call.localCameraEnabled
        activeVoiceCall?.localCameraEnabled = desired
        Task { [weak self, videoMediaClient] in
            do {
                try await videoMediaClient.setCameraEnabled(desired)
                guard let self, self.activeVoiceCall?.callID == callID else { return }
                self.activeVoiceCall?.localCameraEnabled = desired
            } catch {
                guard let self, self.activeVoiceCall?.callID == callID else { return }
                if self.activeVoiceCall?.localCameraEnabled == desired {
                    self.activeVoiceCall?.localCameraEnabled = previous
                }
                self.toast = desired ? "摄像头开启失败，请稍后重试" : "摄像头关闭失败，请稍后重试"
            }
        }
    }

    func switchActiveVideoCamera() {
        guard let call = activeVoiceCall, call.mediaMode == "video" else { return }
        let callID = call.callID ?? ""
        let previous = call.cameraPosition
        let desired: VideoCallCameraPosition = call.cameraPosition == .front ? .back : .front
        activeVoiceCall?.cameraPosition = desired
        Task { [weak self, videoMediaClient] in
            do {
                try await videoMediaClient.switchCamera()
                guard let self, self.activeVoiceCall?.callID == callID else { return }
                self.activeVoiceCall?.cameraPosition = desired
            } catch {
                guard let self, self.activeVoiceCall?.callID == callID else { return }
                if self.activeVoiceCall?.cameraPosition == desired {
                    self.activeVoiceCall?.cameraPosition = previous
                }
                self.toast = "切换摄像头失败，已保留原摄像头"
            }
        }
    }

    func setActiveVideoCallMinimized(_ minimized: Bool) {
        activeVoiceCall?.isMinimized = minimized
    }

    func downgradeActiveVideoCallToAudio() {
        guard let call = activeVoiceCall, call.mediaMode == "video" else { return }
        guard guardCallLicenseForAction(.voice) else { return }
        let context = apiContext
        guard let callID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !callID.isEmpty,
              context.hasIMSession else {
            toast = "通话状态尚未同步，暂时无法切换为语音"
            return
        }
        let scope = remoteDataScopeKey(for: context)
        let previousStatusText = call.statusText
        let capabilityGeneration = callLicenseActionGeneration(for: .voice)
        let binding = DirectCallContextBinding(context: context)
        activeVoiceCall?.statusText = "正在切换为语音通话"
        Task { [weak self, api, videoMediaClient] in
            guard let self else { return }
            defer {
                if self.activeVoiceCall?.callID == callID,
                   self.activeVoiceCall?.statusText == "正在切换为语音通话" {
                    self.activeVoiceCall?.statusText = previousStatusText
                }
            }
            do {
                _ = try await self.currentFileUploadConfig(
                    context: try self.currentDirectCallRequestContext(context),
                    scope: scope
                )
                guard DirectCallContextBinding(context: self.apiContext) == binding,
                      self.guardCallLicenseForAction(.voice),
                      self.callLicenseActionGeneration(for: .voice) == capabilityGeneration,
                      self.activeVoiceCall?.callID == callID else { return }
                let provider = try await api.rtcProvider(
                    context: try self.currentDirectCallRequestContext(context)
                )
                guard DirectCallContextBinding(context: self.apiContext) == binding,
                      self.callLicenseActionGeneration(for: .voice) == capabilityGeneration,
                      self.activeVoiceCall?.callID == callID else { return }
                try self.requireRTCLicense(provider.voiceCallEnabled, media: .voice)
                _ = try await api.downgradeRTCCall(
                    context: try self.currentDirectCallRequestContext(context),
                    callID: callID,
                    reason: "user_downgrade"
                )
                guard self.isCurrentRemoteScope(scope),
                      self.callLicenseActionGeneration(for: .voice) == capabilityGeneration,
                      self.activeVoiceCall?.callID == callID else { return }
                var mediaSignalFailed = false
                do {
                    try await videoMediaClient.downgradeToAudio()
                } catch {
                    mediaSignalFailed = true
                }
                if var activeCall = self.activeVoiceCall {
                    self.applyVideoAudioDowngrade(to: &activeCall, preservingStatusText: previousStatusText)
                    self.activeVoiceCall = activeCall
                }
                self.toast = mediaSignalFailed
                    ? "已切换为语音通话，对端状态同步可能稍有延迟"
                    : "已切换为语音通话，当前通话无法恢复视频"
            } catch {
                guard self.activeVoiceCall?.callID == callID,
                      DirectCallContextBinding(context: self.apiContext) == binding else { return }
                if self.activeVoiceCall?.statusText == "正在切换为语音通话" {
                    self.activeVoiceCall?.statusText = previousStatusText
                }
                if !self.guardCallLicenseForAction(.voice) { return }
                self.handleRemoteError(error, fallback: "切换为语音通话失败", rtcMedia: .voice)
            }
        }
    }

    func requestActiveAudioCallVideoUpgrade() {
        guard activeVoiceCall?.requestedMediaMode == "video",
              activeVoiceCall?.mediaMode == "audio" else { return }
        guard guardCallLicenseForAction(.video) else { return }
        toast = "当前接口暂不支持切回视频，请重新发起视频通话"
    }

    func handleVideoApplicationDidEnterBackground() {
        guard activeVoiceCall?.isVideoCall == true else { return }
        Task { [videoMediaClient] in await videoMediaClient.applicationDidEnterBackground() }
    }

    func handleVideoApplicationWillEnterForeground() {
        guard let callID = activeVoiceCall?.callID,
              activeVoiceCall?.isVideoCall == true else { return }
        Task { [weak self, videoMediaClient] in
            do {
                try await videoMediaClient.applicationWillEnterForeground()
            } catch {
                guard let self, self.activeVoiceCall?.callID == callID else { return }
                self.activeVoiceCall?.localCameraEnabled = false
                self.toast = "返回前台后摄像头恢复失败，已保持关闭"
            }
        }
    }

    func handleVoiceMediaEvent(
        _ event: RTCVoiceMediaEvent,
        callID: String? = nil,
        scope: String? = nil,
        operationID: UUID? = nil,
        now: Date = Date()
    ) {
        guard !isEndingActiveCall else { return }
        if let scope, !isCurrentRemoteScope(scope) { return }
        if let operationID,
           !voiceMediaOperationIsCurrent(operationID) {
            return
        }
        guard var call = activeVoiceCall else { return }
        let normalizedCallID = callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedCallID.isEmpty,
           call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedCallID {
            return
        }
        voiceDebug("media_event call=\(Self.shortDebugID(normalizedCallID.isEmpty ? (call.callID ?? "") : normalizedCallID)) event=\(event.rawValue) state=\(event.mediaState.rawValue)")
        if event == .recoveryExhausted {
            voiceDebug("media_recovery_exhausted issue=media_degrade_or_long_call_end call=\(Self.shortDebugID(normalizedCallID.isEmpty ? (call.callID ?? "") : normalizedCallID))")
            let failedCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let requestContext = apiContext
            finishVoiceCallFromRemote(
                status: "连接失败",
                subtitle: "语音通话 · 网络恢复失败",
                toastText: "语音连接恢复失败，通话已结束",
                endReason: "ice_recovery_failed",
                expectedCallID: failedCallID,
                lifecyclePhase: .failure
            )
            if !failedCallID.isEmpty, requestContext.hasIMSession {
                enqueueRTCTerminalCompensation(
                    callID: failedCallID,
                    action: .hangup,
                    reason: "ice_recovery_failed",
                    context: requestContext
                )
            }
            return
        }
        if event == .closed {
            finishVoiceCallFromRemote(
                status: "已结束",
                subtitle: "语音通话 · 通话已结束",
                toastText: "语音通话已结束",
                expectedCallID: call.callID,
                lifecyclePhase: .ended
            )
            return
        }
        switch event {
        case .iceConnected, .iceCompleted, .peerConnectionConnected, .connectionRecovered:
            call.voiceTransportConnected = true
        case .remoteAudioTrackReady:
            call.remoteAudioTrackReady = true
        case .remoteAudioRTPReady:
            call.voiceTransportConnected = true
            call.remoteAudioRTPReady = true
        case .iceDisconnected:
            call.voiceTransportConnected = false
            call.remoteAudioRTPReady = false
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：媒体启动失败参与同一失败状态清理
        case .iceFailed, .mediaStartFailed, .recoveryExhausted, .closed:
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            call.voiceTransportConnected = false
            call.remoteAudioRTPReady = false
        default:
            break
        }
        let readinessEvent = [
            RTCVoiceMediaEvent.iceConnected,
            .iceCompleted,
            .peerConnectionConnected,
            .connectionRecovered,
            .remoteAudioTrackReady,
            .remoteAudioRTPReady
        ].contains(event)
        let effectiveMediaState: RTCVoiceMediaState
        if readinessEvent {
            // JHT_MOD_BEGIN RTC_VOICE_TRANSPORT_CONNECTED_TIMER_20260914 - 修改开始：语音 connected/计时锚点只依赖传输连通，避免跨端远端音轨事件延迟导致不计时
            effectiveMediaState = (call.voiceTransportConnected || call.remoteAudioRTPReady) ? .connected : .connecting
            // JHT_MOD_END RTC_VOICE_TRANSPORT_CONNECTED_TIMER_20260914 - 修改结束
        } else {
            effectiveMediaState = event.mediaState
        }
        if event == .callAccepted,
           [.connected, .unstable, .failed].contains(call.mediaState) {
            voiceDebug("media_event_ignored call=\(Self.shortDebugID(normalizedCallID.isEmpty ? (call.callID ?? "") : normalizedCallID)) event=\(event.rawValue) current=\(call.mediaState.rawValue)")
            return
        }
        if call.mediaState == .connected,
           [.preparing, .signaling, .connecting].contains(effectiveMediaState) {
            voiceDebug("media_event_ignored call=\(Self.shortDebugID(normalizedCallID.isEmpty ? (call.callID ?? "") : normalizedCallID)) event=\(event.rawValue) current=\(call.mediaState.rawValue)")
            return
        }
        if call.mediaState == .failed, effectiveMediaState != .closed {
            voiceDebug("media_event_ignored call=\(Self.shortDebugID(normalizedCallID.isEmpty ? (call.callID ?? "") : normalizedCallID)) event=\(event.rawValue) current=\(call.mediaState.rawValue)")
            return
        }
        call.mediaState = effectiveMediaState
        call.statusText = voiceCallStatusText(for: effectiveMediaState, current: call)
        if effectiveMediaState.qualifiesForConnectedAt, call.connectedAt == nil {
            call.connectedAt = now
            cancelVoiceCallWatchdog()
        }
        activeVoiceCall = call
        updateRTCMediaStateHeartbeat(rtcMediaStateForHeartbeat(call))
        let currentCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch effectiveMediaState {
        case .connected:
            _ = advanceCallLifecycle(callID: currentCallID, to: .connected, reason: "voice_media_connected")
        case .unstable:
            _ = advanceCallLifecycle(callID: currentCallID, to: .reconnecting, reason: "voice_media_reconnecting")
        case .failed:
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：本地 accepted 后不可恢复失败时，清理前保留上下文并补偿 hangup
            let requestContext = apiContext
            let isMediaStartFailure = event == .mediaStartFailed
            let endReason = isMediaStartFailure ? "media_start_failed" : "media_failed"
            finishVoiceCallFromRemote(
                status: "连接失败",
                subtitle: isMediaStartFailure ? "语音通话 · 音频设备启动失败" : "语音通话 · 媒体连接失败",
                toastText: isMediaStartFailure ? "音频设备启动失败，通话已结束" : "语音通话连接失败",
                endReason: endReason,
                expectedCallID: currentCallID,
                lifecyclePhase: .failure
            )
            if !currentCallID.isEmpty, requestContext.hasIMSession {
                enqueueRTCTerminalCompensation(
                    callID: currentCallID,
                    action: .hangup,
                    reason: endReason,
                    context: requestContext
                )
            }
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        case .preparing, .signaling, .connecting, .closed:
            break
        }
    }

    private func currentRTCQualityRequestContext(_ session: RTCQualityReportingSession, rtcToken: String) throws -> IMAPIContext {
        let mediaMode = activeVoiceCall?.mediaMode ?? session.mediaMode
        let licensed = mediaMode == "audio"
            ? isVoiceCallLicensedForCurrentTenant : isVideoCallLicensedForCurrentTenant
        return try session.requestContext(
            current: apiContext, authenticated: isAuthenticated,
            scopeIsCurrent: isCurrentRemoteScope(session.scope), licensed: licensed,
            activeCallID: activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines),
            activeDirection: activeVoiceCall?.direction,
            generation: rtcMediaHeartbeatGeneration, rtcToken: rtcToken
        )
    }

    private func currentRTCMediaRequestContext(generation: UInt64) throws -> IMAPIContext {
        guard !isEndingActiveCall,
              let session = rtcMediaHeartbeatSession,
              session.generation == generation,
              isRTCMediaHeartbeatCurrent(session),
              let call = activeVoiceCall else { throw CancellationError() }
        let licensed = call.mediaMode == "audio"
            ? isVoiceCallLicensedForCurrentTenant : isVideoCallLicensedForCurrentTenant
        guard licensed else { throw CancellationError() }
        return session.context
    }

    private func awaitRTCMediaStage<Value>(
        generation: UInt64,
        operation: (IMAPIContext) async throws -> Value
    ) async throws -> Value {
        let context = try currentRTCMediaRequestContext(generation: generation)
        do {
            let value = try await operation(context)
            _ = try currentRTCMediaRequestContext(generation: generation)
            return value
        } catch {
            _ = try currentRTCMediaRequestContext(generation: generation)
            _ = presentRTCLicenseFailure(error, media: activeVoiceCall?.mediaMode == "audio" ? .voice : .video)
            throw error
        }
    }

    private func isCurrentRTCMediaOperation(_ operationID: UUID) -> Bool {
        guard let session = rtcMediaHeartbeatSession,
              session.operationID == operationID else { return false }
        return isRTCMediaHeartbeatCurrent(session)
    }

    private func voiceMediaOperationIsCurrent(_ operationID: UUID) -> Bool {
        if isCurrentRTCMediaOperation(operationID) { return true }
        if currentDirectCallAttempt(for: .voice)?.operationID == operationID {
            return true
        }
        guard let activeCall = activeVoiceCall,
              activeCall.isVideoCall,
              activeCall.mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "audio" else {
            return false
        }
        return currentDirectCallAttempt(for: .video)?.operationID == operationID
    }

    private func voiceCallStatusText(for mediaState: RTCVoiceMediaState, current call: VoiceCallSession) -> String {
        switch mediaState {
        case .preparing, .signaling, .connecting:
            return "连接中"
        case .connected:
            return "通话中"
        case .unstable:
            return "连接不稳定"
        case .failed:
            return "通话失败"
        case .closed:
            return "已结束"
        }
    }

    func toggleActiveCallMuted() {
        let nextValue = !(activeVoiceCall?.isMuted ?? false)
        voiceDebug("ui_action_mute call=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) muted=\(nextValue)")
        setActiveVoiceCallMuted(nextValue, notifySystem: true)
    }

    private func setActiveVoiceCallMuted(_ isMuted: Bool, notifySystem: Bool) {
        guard activeVoiceCall != nil else { return }
        guard isVoiceMediaClientAvailable else {
            toast = voiceMediaClientUnavailableReason
            return
        }
        activeVoiceCall?.isMuted = isMuted
        let callID = activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if activeVoiceCall?.isVideoCall == true {
            Task { [videoMediaClient] in await videoMediaClient.setMuted(isMuted) }
        } else {
            Task { [voiceMediaClient] in await voiceMediaClient.setMuted(isMuted) }
        }
        if notifySystem, !callID.isEmpty {
            voiceCallSystem.setMuted(callID: callID, isMuted: isMuted)
        }
    }

    func toggleActiveCallSpeaker() {
        guard let call = activeVoiceCall else { return }
        guard isVoiceMediaClientAvailable else {
            toast = voiceMediaClientUnavailableReason
            return
        }
        let callID = call.callID ?? ""
        let speakerOn = !call.speakerOn
        voiceDebug("ui_action_speaker call=\(Self.shortDebugID(callID)) speaker=\(speakerOn)")
        if call.isVideoCall {
            activeVoiceCall?.speakerOn = speakerOn
            Task { [weak self, videoMediaClient] in
                do {
                    try await videoMediaClient.setSpeakerEnabled(speakerOn)
                    guard let self, self.activeVoiceCall?.callID == callID else { return }
                    self.activeVoiceCall?.speakerOn = speakerOn
                } catch {
                    guard let self, self.activeVoiceCall?.callID == callID else { return }
                    if self.activeVoiceCall?.speakerOn == speakerOn {
                        self.activeVoiceCall?.speakerOn = call.speakerOn
                    }
                    self.toast = "视频通话音频路由切换失败"
                }
            }
        } else {
            activeVoiceCall?.speakerOn = speakerOn
            Task { [voiceMediaClient] in
                await voiceMediaClient.setSpeakerEnabled(speakerOn)
            }
        }
    }

    func dismissVideoCallTerminalResult() {
        videoCallTerminalResult = nil
    }

    private func presentVideoCallTerminal(
        callID: String = "",
        peer: IMUser,
        reason: String,
        fallback: String,
        connectedAt: Date? = nil,
        endedAt: Date = Date()
    ) {
        guard videoCallTerminalResult == nil else {
            voiceDebug("video_terminal_skip reason=already_presented")
            return
        }
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCallID.isEmpty,
           !presentedVideoTerminalCallIDs.insert(normalizedCallID).inserted {
            voiceDebug("video_terminal_skip reason=duplicate call=\(Self.shortDebugID(normalizedCallID))")
            return
        }
        let durationText = connectedAt.map {
            VideoCallDurationFormatter.text(connectedAt: $0, now: endedAt)
        } ?? ""
        videoCallTerminalResult = VideoCallTerminalResult(
            callID: normalizedCallID,
            peer: peer,
            reason: reason,
            fallback: fallback,
            durationText: durationText
        )
    }

    private func applyVideoAudioDowngrade(to call: inout VoiceCallSession, preservingStatusText: String? = nil) {
        let statusBeforeDowngrade = (preservingStatusText ?? call.statusText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        call.mediaMode = "audio"
        call.localCameraEnabled = false
        call.remoteCameraEnabled = false
        call.remoteVideoTrackReady = false
        call.isRecoveringNetwork = false
        if !statusBeforeDowngrade.isEmpty,
           statusBeforeDowngrade != "正在切换为语音通话" {
            call.statusText = statusBeforeDowngrade
        } else if call.connectedAt != nil || call.mediaState == .connected {
            call.statusText = "通话中"
        } else if call.direction == "呼出", call.mediaState == .preparing {
            call.statusText = "等待对方接听"
        } else {
            call.statusText = "连接中"
        }
    }

    func endActiveVoiceCall() {
        guard let call = activeVoiceCall, !isEndingActiveCall else { return }
        voiceDebug("ui_action_end call=\(Self.shortDebugID(call.callID ?? "")) media=\(call.mediaMode) state=\(call.mediaState.rawValue)")
        SystemNotificationSound.stopIncomingCallFallback()
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        cancelVoiceCallWatchdog()
        let normalizedCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedCallID.isEmpty, context.hasIMSession else {
            // JHT_MOD_BEGIN RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改开始：轻量视频占位未获得服务端 callID 前，挂断等同取消本次发起任务
            if call.isVideoCall,
               call.direction == "呼出",
               isStartingVideoCall,
               let attempt = currentDirectCallAttempt(for: .video),
               attempt.callID.isEmpty,
               pendingOutgoingVideoCallPresentation(for: attempt)?.id == call.id {
                callStore.videoCallStartGeneration = nil
                clearCurrentDirectCallAttempt(kind: .video, operationID: attempt.operationID)
                isStartingVideoCall = false
                activeCallEndError = nil
                activeVoiceCall = nil
                toast = "已取消视频通话"
                return
            }
            // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
            activeCallEndError = "登录会话不可用，无法结束通话，请重新登录后重试"
            toast = activeCallEndError
            return
        }
        isEndingActiveCall = true
        activeCallEndError = nil
        // Stop local capture and audio immediately for privacy. The call UI remains until
        // the authoritative server transition succeeds or a terminal event arrives.
        rtcMediaHeartbeatSession?.isFinishing = true
        let endingHeartbeatGeneration = rtcMediaHeartbeatGeneration
        stopCallMediaSession(for: call, reason: "user_ending", preserveHeartbeat: true)
        releaseAudioSessionForVoiceCall()
        let lifecycleSnapshot = callStore.activeLifecycleSnapshot
        let shouldCancel = call.direction == "呼出"
            && lifecycleSnapshot?.hasEverConnected != true
            && (lifecycleSnapshot.map { [.dialing, .ringing].contains($0.phase) }
                ?? Self.shouldCancelActiveCall(call))
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        let terminalAction: RTCTerminalCompensationAction = shouldCancel ? .cancel : .hangup
        let terminalReason = shouldCancel ? "user_cancel" : "user_hangup"
        let idempotencyKey = stableRTCTerminalMutationIdempotencyKey(
            callID: normalizedCallID,
            action: terminalAction,
            reason: terminalReason,
            context: context
        )
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        let recordsBeforeLocalEnd = calls
        upsertEndedVoiceCallRecord(
            call,
            callID: normalizedCallID,
            endedAt: Date()
        )
        Task {
            var expectedEndingGeneration = endingHeartbeatGeneration
            do {
                let connectionReportConfirmed = await finishRTCMediaHeartbeatBeforeHangup(call: call)
                guard isAuthenticated,
                      isCurrentRemoteScope(scope),
                      apiContext.deviceID == context.deviceID,
                      apiContext.sessionEpoch == context.sessionEpoch,
                      rtcMediaHeartbeatGeneration == endingHeartbeatGeneration,
                      activeVoiceCall?.callID == call.callID,
                      isEndingActiveCall else { throw CancellationError() }
                stopRTCMediaStateHeartbeat(reason: "user_ending")
                expectedEndingGeneration = rtcMediaHeartbeatGeneration
                if shouldCancel {
                    try await api.cancelRTCCall(
                        context: context,
                        callID: normalizedCallID,
                        reason: terminalReason,
                        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                        idempotencyKey: idempotencyKey
                        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    )
                } else {
                    try await api.hangupRTCCall(
                        context: context,
                        callID: normalizedCallID,
                        reason: terminalReason,
                        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                        idempotencyKey: idempotencyKey
                        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    )
                }
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                clearRTCTerminalCompensationIfMatches(
                    callID: normalizedCallID,
                    action: terminalAction,
                    idempotencyKey: idempotencyKey
                )
                // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                guard isAuthenticated,
                      isCurrentRemoteScope(scope),
                      apiContext.deviceID == context.deviceID,
                      apiContext.accountID == context.accountID,
                      apiContext.sessionEpoch == context.sessionEpoch,
                      rtcMediaHeartbeatGeneration == expectedEndingGeneration,
                      activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID else {
                    return
                }
                finishActiveVoiceCallAfterServerTransition(
                    call,
                    callID: normalizedCallID,
                    wasCancelled: shouldCancel
                )
                if !connectionReportConfirmed {
                    toast = "通话已结束，连接记录同步未确认"
                }
            } catch {
                guard isAuthenticated,
                      isCurrentRemoteScope(scope),
                      apiContext.deviceID == context.deviceID,
                      apiContext.accountID == context.accountID,
                      apiContext.sessionEpoch == context.sessionEpoch,
                      rtcMediaHeartbeatGeneration == expectedEndingGeneration,
                      activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID else {
                    return
                }
                if isRTCCallAlreadyTerminalError(error) {
                    finishActiveVoiceCallAfterServerTransition(
                        call,
                        callID: normalizedCallID,
                        wasCancelled: shouldCancel
                    )
                    return
                }
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                enqueueRTCTerminalCompensationAfterInitialFailure(
                    callID: normalizedCallID,
                    action: terminalAction,
                    reason: terminalReason,
                    context: context,
                    idempotencyKey: idempotencyKey,
                    error: error
                )
                // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                calls = recordsBeforeLocalEnd
                isEndingActiveCall = false
                activeCallEndError = "未能结束通话，请检查网络后重试"
                toast = activeCallEndError
            }
        }
    }

    private func finishRTCMediaHeartbeatBeforeHangup(call: VoiceCallSession) async -> Bool {
        guard call.connectedAt != nil else { return true }
        guard let initial = rtcMediaHeartbeatSession,
              initial.callID == call.callID,
              isRTCMediaHeartbeatCurrent(initial) else { return false }
        if initial.hasReportedConnected { return true }
        renewRTCMediaStateHeartbeatNow(reason: "ending_flush")
        // Capture is already stopped. Give the single existing renewal loop at
        // most two seconds to acknowledge qualified media; never hold hangup on
        // an unresponsive transport or fabricate a successful connection.
        for _ in 0..<100 {
            guard let current = rtcMediaHeartbeatSession,
                  current.generation == initial.generation,
                  isRTCMediaHeartbeatCurrent(current) else { return false }
            if current.hasReportedConnected { return true }
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return false }
        }
        voiceDebug("media_heartbeat_end_unconfirmed call=\(Self.shortDebugID(initial.callID))")
        return rtcMediaHeartbeatSession?.hasReportedConnected == true
    }

    static func shouldCancelActiveCall(_ call: VoiceCallSession) -> Bool {
        guard call.direction == "呼出", call.connectedAt == nil else { return false }
        switch call.mediaState {
        case .preparing, .signaling:
            return true
        case .connecting, .connected, .unstable, .failed, .closed:
            return false
        }
    }

    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: only apply outgoing ringing timeout while it is still truly ringing.
    private static func shouldRunOutgoingRingingTimeout(_ call: VoiceCallSession) -> Bool {
        guard shouldCancelActiveCall(call) else { return false }
        return call.statusText.trimmingCharacters(in: .whitespacesAndNewlines) == "等待对方接听"
    }
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END

    private func isRTCCallAlreadyTerminalError(_ error: Error) -> Bool {
        let code = RTCMediaStateHeartbeatFailurePolicy.normalizedErrorCode(error)
        if code == "rtc_call_not_active" || code == "rtc_call_not_found" {
            return true
        }
        let message = userFacingError(error)
        return message.contains("该通话已结束")
            || message.contains("通话不存在或已结束")
    }

    private func finishActiveVoiceCallAfterServerTransition(
        _ call: VoiceCallSession,
        callID: String,
        wasCancelled: Bool
    ) {
        _ = advanceCallLifecycle(
            callID: callID,
            to: wasCancelled ? .cancelled : .ended,
            reason: wasCancelled ? "local_cancel" : "local_hangup"
        )
        let endedAt = Date()
        voiceCallSystem.endCall(callID: callID, reason: "local_hangup")
        voipPushPayloadsByCallID.removeValue(forKey: callID)
        let callKind = call.isVideoCall ? "视频" : "语音"
        upsertEndedVoiceCallRecord(call, callID: callID, endedAt: endedAt)
        // JHT_MOD_BEGIN RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改开始：通话终态后静默补拉对应私聊消息，接收服务端权威 rtc_call_record
        if !call.isVideoCall {
            syncRTCCallRecordConversationAfterTerminalIfPossible(
                channelID: nil,
                peer: call.peer,
                peerUID: nil,
                phase: wasCancelled ? .cancelled : .ended,
                reason: wasCancelled ? "local_cancel" : "local_hangup"
            )
        }
        // JHT_MOD_END RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改结束
        releaseDirectCallTracking(callID: callID)
        if call.isVideoCall {
            rtcTerminalMarkersByCallID[callID] = RTCCallTerminalMarker(
                callID: callID,
                reason: wasCancelled ? "local_cancel" : "local_hangup",
                stateVersion: max(0, call.stateVersion)
            )
            activeVoiceCall = nil
            // JHT_MOD_BEGIN RTC_VIDEO_LOCAL_HANGUP_TERMINAL_POPUP_FIX_20260912 - 修改开始：本地手动挂断视频后不再弹结果页，避免返回聊天时 fullScreenCover 反复拉起
            videoCallTerminalResult = nil
            // JHT_MOD_END RTC_VIDEO_LOCAL_HANGUP_TERMINAL_POPUP_FIX_20260912 - 修改结束
        } else {
            activeVoiceCall = nil
        }
        rtcPeerWaitTerminationCallIDs.remove(callID)
        toast = "\(callKind)通话已结束"
    }

    // JHT_MOD_BEGIN RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改开始：只补同步已有私聊，不本地伪造通话消息
    private func syncRTCCallRecordConversationAfterTerminalIfPossible(
        channelID: String?,
        peer: IMUser?,
        peerUID: String?,
        phase: CallLifecyclePhase,
        reason: String
    ) {
        guard phase.isTerminal,
              isAuthenticated,
              apiContext.hasIMSession else { return }
        guard let conversation = directConversationForRTCCallRecordSync(
            channelID: channelID,
            peer: peer,
            peerUID: peerUID
        ) else {
            voiceDebug("call_record_chat_sync_skip reason=no_direct_conversation phase=\(phase.rawValue) terminal_reason=\(reason)")
            return
        }
        let conversationID = conversation.id
        let scope = remoteDataScopeKey(for: apiContext)
        let sessionEpoch = apiContext.sessionEpoch
        let delays: [UInt64] = [350_000_000, 1_500_000_000]
        voiceDebug("call_record_chat_sync_schedule conversation=\(Self.shortDebugID(conversationID)) phase=\(phase.rawValue) reason=\(reason)")
        for (index, delay) in delays.enumerated() {
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.isAuthenticated,
                      self.apiContext.hasIMSession,
                      self.apiContext.sessionEpoch == sessionEpoch,
                      self.isCurrentRemoteScope(scope),
                      self.conversations.contains(where: { $0.id == conversationID }) else { return }
                self.voiceDebug("call_record_chat_sync_fire conversation=\(Self.shortDebugID(conversationID)) attempt=\(index + 1) phase=\(phase.rawValue) reason=\(reason)")
                self.syncConversationMessagesIfNeeded(
                    conversationID,
                    force: true,
                    silent: true,
                    showLoadingIndicator: false,
                    trimToLatestWindow: true
                )
            }
        }
    }

    private func directConversationForRTCCallRecordSync(
        channelID: String?,
        peer: IMUser?,
        peerUID: String?
    ) -> Conversation? {
        let normalizedChannelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerUID = peerUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let conversation = directConversationForVoiceCall(
            uid: normalizedPeerUID,
            channelID: normalizedChannelID
        ) {
            return conversation
        }
        if !normalizedChannelID.isEmpty,
           let conversation = conversations.first(where: {
               $0.kind == .direct
                   && ($0.id == normalizedChannelID || remoteChannelID(for: $0) == normalizedChannelID)
           }) {
            return conversation
        }
        if let peer {
            for candidate in userIdentityCandidates(for: peer) {
                if let conversation = directConversationForVoiceCall(
                    uid: candidate,
                    channelID: normalizedChannelID
                ) {
                    return conversation
                }
            }
        }
        return nil
    }
    // JHT_MOD_END RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改结束

    private func upsertEndedVoiceCallRecord(
        _ call: VoiceCallSession,
        callID: String,
        endedAt: Date
    ) {
        let direction: CallRecordDirection = call.direction == "来电" ? .incoming : .outgoing
        let callKind = call.isVideoCall ? "视频" : "语音"
        let subtitle = direction == .incoming ? "\(callKind)来电 · 通话已结束" : "\(callKind)呼出 · 通话已结束"
        upsertVoiceCallRecord(
            callID: call.callID ?? callID,
            title: call.peer.name,
            subtitle: subtitle,
            status: "已结束",
            direction: direction,
            peer: call.peer,
            startedAt: call.startedAtDate,
            endedAt: endedAt,
            durationSeconds: voiceCallDurationSeconds(for: call, endedAt: endedAt, finalStatus: "已结束")
        )
    }

    private func stopCallMediaSession(for call: VoiceCallSession?, reason: String, preserveHeartbeat: Bool = false) {
        AccessDiagnostics.shared.clearTurnServers(callID: call?.callID)
        if rtcQualityReportingSession?.callID == call?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) {
            rtcQualityReportingSession?.finish()
        }
        if !preserveHeartbeat {
            stopRTCMediaStateHeartbeat(reason: reason)
        }
        let normalizedCallID = call?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ownsVideoMedia = (!normalizedCallID.isEmpty && activeVideoMediaCallID == normalizedCallID)
            || (call?.isVideoCall == true && activeVoiceMediaCallID != normalizedCallID)
        if ownsVideoMedia {
            if !normalizedCallID.isEmpty,
               !stoppedVideoMediaCallIDs.insert(normalizedCallID).inserted {
                return
            }
            videoMediaEventTask?.cancel()
            videoMediaEventTask = nil
            activeVideoMediaCallID = nil
            Task { [videoMediaClient] in
                await videoMediaClient.stop(reason: reason)
            }
        } else {
            stopVoiceMediaSession(reason: reason)
        }
    }

    private func ensureMicrophonePermissionForVoiceCall() async -> Bool {
        if let microphonePermissionDecisionOverride {
            return await microphonePermissionDecisionOverride()
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                toast = "麦克风权限未开启，请在系统设置中允许 问达通 使用麦克风"
            }
            return granted
        case .denied, .restricted:
            toast = "麦克风权限未开启，请在系统设置中允许 问达通 使用麦克风"
            return false
        @unknown default:
            toast = "当前设备无法使用麦克风"
            return false
        }
    }

    private func configureAudioSessionForVoiceCall() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else {
            throw IMAPIError.server("当前设备无法使用麦克风")
        }
    }

    func releaseAudioSessionForVoiceCall() {
        SystemNotificationSound.stopAllCallPrompts()
    }

    private func rtcCallFailureReason(for error: Error, defaultReason: String) -> String {
        let message = userFacingError(error).lowercased()
        if message.contains("麦克风") || message.contains("audio") || message.contains("microphone") || message.contains("capture") {
            return "capture_failed"
        }
        return defaultReason
    }

    private func normalizedVoiceCallTimeoutSeconds(_ seconds: Int?) -> UInt64 {
        let value = seconds ?? defaultVoiceCallTimeoutSeconds
        return UInt64(min(max(value, 10), 180))
    }

    private func scheduleOutgoingVoiceCallWatchdog(callID: String, scope: String, timeoutSeconds: Int?) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              isCurrentRemoteScope(scope) else { return }
        cancelVoiceCallWatchdog()
        let timeout = normalizedVoiceCallTimeoutSeconds(timeoutSeconds)
        callStore.replaceVoiceCallWatchdogTask(Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.runOutgoingVoiceCallWatchdog(callID: normalizedCallID, scope: scope)
            }
        })
    }

    func cancelVoiceCallWatchdog() {
        callStore.cancelVoiceCallWatchdogTask()
    }

    private func runOutgoingVoiceCallWatchdog(callID: String, scope: String) {
        guard isCurrentRemoteScope(scope) else {
            cancelVoiceCallWatchdog()
            return
        }
        guard let activeCall = activeVoiceCall,
              activeCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID,
              Self.shouldRunOutgoingRingingTimeout(activeCall) else {
            cancelVoiceCallWatchdog()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let context = await MainActor.run { self.apiContext }
            guard await MainActor.run(body: { self.isCurrentRemoteScope(scope) }) else { return }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            await self.refreshRTCSignalingSilently(context: context, scope: scope)
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            await MainActor.run {
                guard self.isCurrentRemoteScope(scope) else {
                    self.cancelVoiceCallWatchdog()
                    return
                }
                guard let activeCall = self.activeVoiceCall,
                      activeCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID,
                      Self.shouldRunOutgoingRingingTimeout(activeCall) else {
                    self.cancelVoiceCallWatchdog()
                    return
                }
                self.cancelVoiceCallWatchdog()
                self.voiceDebug("outgoing_watchdog_timeout issue=connect_drop call=\(Self.shortDebugID(callID))")
                Task {
                    try? await self.api.timeoutRTCCall(context: context, callID: callID, reason: "client_watchdog_timeout")
                }
                self.finishVoiceCallFromRemote(
                    status: "未接通",
                    subtitle: "语音呼出 · 已超时",
                    toastText: "语音通话已超时",
                    endReason: "client_watchdog_timeout",
                    expectedCallID: callID,
                    lifecyclePhase: .timeout
                )
            }
        }
    }

    @discardableResult
    func handleRTCCallEvent(_ envelope: RealtimeEnvelope, scope: String? = nil) -> Bool {
        if let scope {
            guard isCurrentRemoteScope(scope) else { return false }
        }
        let payload = envelope.payload["rtc_call"]?.objectValue ?? envelope.payload
        let callPayload = payload["call"]?.objectValue ?? [:]
        let event = (payload["event"]?.stringValue ?? envelope.type).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let status = (payload["status"]?.stringValue ?? callPayload["status"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let callID = (payload["call_id"]?.stringValue ?? payload["id"]?.stringValue ?? callPayload["call_id"]?.stringValue ?? callPayload["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let terminalStateVersion = Int64(
            payload["state_version"]?.stringValue
                ?? payload["stateVersion"]?.stringValue
                ?? callPayload["state_version"]?.stringValue
                ?? callPayload["stateVersion"]?.stringValue
                ?? ""
        ) ?? 0
        let terminalReason = rtcTerminalReason(
            event: event,
            status: status,
            payload: payload,
            callPayload: callPayload
        )
        let historicalTiming = rtcHistoricalCallTiming(payload: payload, callPayload: callPayload)
        let callerUID = (payload["caller_uid"]?.stringValue ?? payload["from_uid"]?.stringValue ?? callPayload["caller_uid"]?.stringValue ?? callPayload["from_uid"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let calleeUID = (payload["callee_uid"]?.stringValue ?? payload["target_uid"]?.stringValue ?? callPayload["callee_uid"]?.stringValue ?? callPayload["target_uid"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roomID = (payload["room_id"]?.stringValue ?? callPayload["room_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = (payload["channel_id"]?.stringValue ?? callPayload["channel_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let identities = currentUserIdentitySet()
        let peerUID = identities.contains(callerUID) ? calleeUID : callerUID
        let peer = voiceCallPeer(
            from: payload,
            callPayload: callPayload,
            peerUID: peerUID,
            peerRole: identities.contains(callerUID) ? .callee : .caller,
            channelID: channelID
        )
        refreshVoiceCallPeerIfBetter(peer, matching: callID)

        if !callID.isEmpty,
           !terminalReason.isEmpty,
           activeVoiceCall?.callID != callID,
           incomingVoiceCall?.callID != callID,
           rtcTerminalMarkersByCallID[callID] != nil {
            refineTerminalMarkerAndRecord(
                callID: callID,
                reason: terminalReason,
                stateVersion: terminalStateVersion,
                historicalTiming: historicalTiming
            )
            return true
        }

        if event == "rtc.call.ringing" || status == "ringing" {
            guard !callerUID.isEmpty,
                  !identities.contains(callerUID),
                  calleeUID.isEmpty || identities.contains(calleeUID) else { return false }
            // A delayed ringing event for an already answered call is a replay,
            // not a competing incoming call. Pending same-ID calls are refined
            // by receiveIncomingVoiceCall's existing admission/ownership logic.
            if !callID.isEmpty, activeVoiceCall?.callID == callID {
                return true
            }
            if let reason = incomingVoiceCallUnavailableReason(for: peer) {
                if !callID.isEmpty {
                    rejectPresentedIncomingCallForAdmissionFailure(
                        callID: callID,
                        reason: "incoming_admission_unavailable"
                    )
                }
                toast = reason
                return true
            }
            if activeVoiceCall != nil
                || (incomingVoiceCall != nil && incomingVoiceCall?.callID != callID) {
                if !callID.isEmpty {
                    rejectCompetingIncomingCallIfPossible(callID: callID)
                }
                toast = activeVoiceCall != nil ? "当前正在通话中" : "请先处理当前来电"
                return true
            }
            receiveIncomingVoiceCall(
                from: peer,
                callID: callID,
                roomID: roomID,
                mediaMode: requestedRTCCallMediaMode(
                    payload: payload,
                    callPayload: callPayload
                ),
                stateVersion: terminalStateVersion,
                systemOwnsRingtone: voiceCallSystem.hasPresentedCall(callID: callID)
            )
            return true
        }

        if event == "rtc.call.busy" {
            let reasonCode = (payload["reason_code"]?.stringValue ?? payload["code"]?.stringValue ?? "callee_busy")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !callID.isEmpty,
                  activeVoiceCall?.callID == callID || incomingVoiceCall?.callID == callID else {
                voiceDebug("call_busy_ignore reason=foreign_or_empty call=\(Self.shortDebugID(callID))")
                return false
            }
            if advanceCallLifecycle(
                callID: callID,
                to: .busy,
                stateVersion: terminalStateVersion,
                reason: reasonCode
            ) {
                finishVoiceCallFromRemote(
                    status: "忙线",
                    subtitle: "语音通话 · 忙线",
                    toastText: rtcBusyMessage(reasonCode: reasonCode, fallback: payload["reason"]?.stringValue),
                    endReason: reasonCode,
                    stateVersion: terminalStateVersion,
                    expectedCallID: callID,
                    lifecyclePhase: .busy,
                    requiresAuthoritativeRevision: true,
                    lifecycleAlreadyApplied: true,
                    historicalTiming: historicalTiming
                )
            }
            return true
        }

        guard !callID.isEmpty,
              activeVoiceCall?.callID == callID || incomingVoiceCall?.callID == callID else { return false }
        switch event {
        case "rtc.call.accepted":
            if acceptedRTCCallIsBoundToCurrentCallee(
                payload: payload,
                callPayload: callPayload
            ) == false {
                // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: do not treat our in-flight answer as answered elsewhere.
                if shouldDeferAcceptedElsewhereWhileAnswering(callID: callID) {
                    voiceDebug("accepted_elsewhere_deferred issue=connect_drop call=\(Self.shortDebugID(callID)) reason=local_answer_in_progress")
                    return true
                }
                // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END
                finishVoiceCallFromRemote(
                    status: "已在其他设备接听",
                    subtitle: "语音通话 · 已在其他设备接听",
                    toastText: "已在其他设备接听",
                    endReason: "answered_elsewhere",
                    stateVersion: terminalStateVersion,
                    expectedCallID: callID,
                    lifecyclePhase: .ended
                )
                return true
            }
            if activeVoiceCall?.requiresAcceptedDeviceBeforeJoin != true { cancelVoiceCallWatchdog() }
            SystemNotificationSound.setOutgoingRingbackSuppressed(true)
            SystemNotificationSound.stopAllCallPrompts()
            handleVoiceMediaEvent(.callAccepted, callID: callID, scope: scope)
            startVoiceMediaSessionFromActiveCall(
                scope: scope ?? remoteDataScopeKey(for: apiContext),
                authoritativeCall: authoritativeRTCCall(
                    payload: payload,
                    callPayload: callPayload,
                    callID: callID,
                    status: status.isEmpty ? "accepted" : status
                )
            )
            toast = "\(peer.name) 已接听"
        case "rtc.call.rejected":
            finishVoiceCallFromRemote(
                status: "已拒绝",
                subtitle: "语音通话 · 对方已拒绝",
                toastText: "对方已拒绝语音通话",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .rejected,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        case "rtc.call.canceled":
            finishVoiceCallFromRemote(
                status: "已取消",
                subtitle: "语音通话 · 已取消",
                toastText: "语音通话已取消",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .cancelled,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        case "rtc.call.ended":
            finishVoiceCallFromRemote(
                status: "已结束",
                subtitle: "语音通话 · 通话已结束",
                toastText: "语音通话已结束",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .ended,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        case "rtc.call.timed_out":
            finishVoiceCallFromRemote(
                status: "未接通",
                subtitle: "语音通话 · 已超时",
                toastText: "语音通话已超时",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .timeout,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        default:
            break
        }
        return [
            "rtc.call.accepted",
            "rtc.call.rejected",
            "rtc.call.canceled",
            "rtc.call.ended",
            "rtc.call.timed_out"
        ].contains(event)
    }

    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: local answering races can precede accepted-device reconciliation.
    private func shouldDeferAcceptedElsewhereWhileAnswering(callID: String) -> Bool {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return false }
        if let active = activeVoiceCall,
           active.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID,
           active.direction == "来电",
           [.preparing, .signaling, .connecting].contains(active.mediaState) {
            return true
        }
        guard incomingCallAnswerMode != nil
                || callStore.incomingCallAnswerOperationID != nil else {
            return false
        }
        if incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            return true
        }
        return activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID
            && activeVoiceCall?.direction == "来电"
    }
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END

    private func acceptedRTCCallIsBoundToCurrentCallee(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> Bool? {
        let delivery = callPayload["delivery_context"]?.objectValue
            ?? callPayload["deliveryContext"]?.objectValue
            ?? payload["delivery_context"]?.objectValue
            ?? payload["deliveryContext"]?.objectValue
        guard let delivery else { return nil }
        let role = (delivery["viewer_role"]?.stringValue
            ?? delivery["viewerRole"]?.stringValue
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard role == "callee" else { return nil }
        return delivery["viewer_is_bound_participant"]?.boolValue
            ?? delivery["viewerIsBoundParticipant"]?.boolValue
    }

    private func requestedRTCCallMediaMode(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> String {
        // State events carry the authoritative call either at the event root or
        // under `call`. Preserve the requested call type before considering an
        // accepted audio downgrade so a video call is never presented as voice.
        let requestedCandidates = [
            callPayload["call_type"]?.stringValue,
            callPayload["requested_media_mode"]?.stringValue,
            payload["call_type"]?.stringValue,
            payload["requested_media_mode"]?.stringValue
        ]
        let requestedModes = requestedCandidates.compactMap { candidate -> String? in
            switch candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "video": return "video"
            case "audio", "voice": return "audio"
            default: return nil
            }
        }
        if requestedModes.contains("video") { return "video" }
        if requestedModes.contains("audio") { return "audio" }

        let acceptedCandidates = [
            callPayload["media_mode"]?.stringValue,
            payload["media_mode"]?.stringValue,
            callPayload["accept_mode"]?.stringValue,
            payload["accept_mode"]?.stringValue
        ]
        for candidate in acceptedCandidates {
            switch candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "video": return "video"
            case "audio", "voice": return "audio"
            default: continue
            }
        }
        return "audio"
    }

    private func authoritativeRTCCall(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        callID: String,
        status: String
    ) -> RemoteRTCCall? {
        var fields = callPayload
        let copiedKeys = [
            "id", "call_id", "room_id", "rtc_token", "caller_uid", "callee_uid", "target_uid",
            "channel_id", "channel_type", "call_type", "requested_media_mode", "media_mode",
            "peer_capability_status", "caller_device", "callee_device", "accepted_device",
            "caller_device_id", "callee_device_id", "accepted_device_id", "state_version"
        ]
        for key in copiedKeys where fields[key] == nil {
            fields[key] = payload[key]
        }
        if fields["id"] == nil, fields["call_id"] == nil, !callID.isEmpty {
            fields["id"] = .string(callID)
        }
        if fields["status"] == nil {
            fields["status"] = .string(status)
        }

        let callerUID = fields["caller_uid"]?.stringValue ?? ""
        let calleeUID = fields["callee_uid"]?.stringValue
            ?? fields["target_uid"]?.stringValue
            ?? ""
        func normalizedDevice(
            objectKey: String,
            idKeys: [String],
            uid: String
        ) -> JSONValue? {
            if let existing = fields[objectKey]?.objectValue {
                return .object(existing)
            }
            let deviceID = idKeys.lazy.compactMap { key in
                fields[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first(where: { !$0.isEmpty }) ?? ""
            guard !deviceID.isEmpty else { return nil }
            return .object([
                "uid": .string(uid),
                "device_id": .string(deviceID),
                "device_type": .string("")
            ])
        }
        if fields["caller_device"] == nil {
            fields["caller_device"] = normalizedDevice(
                objectKey: "caller_device",
                idKeys: ["caller_device_id"],
                uid: callerUID
            )
        }
        if fields["callee_device"] == nil {
            fields["callee_device"] = normalizedDevice(
                objectKey: "callee_device",
                idKeys: ["callee_device_id", "accepted_device_id"],
                uid: calleeUID
            )
        }
        if fields["accepted_device"] == nil {
            fields["accepted_device"] = normalizedDevice(
                objectKey: "accepted_device",
                idKeys: ["accepted_device_id", "callee_device_id"],
                uid: calleeUID
            )
        }
        guard let data = try? JSONEncoder().encode(fields),
              let call = try? JSONDecoder().decode(RemoteRTCCall.self, from: data),
              call.id.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
            return nil
        }
        return call
    }

    private func rtcTerminalReason(
        event: String,
        status: String,
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> String {
        let explicit = (
            payload["end_reason"]?.stringValue
                ?? payload["endReason"]?.stringValue
                ?? payload["reason_code"]?.stringValue
                ?? payload["reason"]?.stringValue
                ?? callPayload["end_reason"]?.stringValue
                ?? callPayload["endReason"]?.stringValue
                ?? callPayload["reason_code"]?.stringValue
                ?? callPayload["reason"]?.stringValue
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        switch event {
        case "rtc.call.rejected": return "rejected"
        case "rtc.call.canceled": return "canceled"
        case "rtc.call.ended": return "remote_hangup"
        case "rtc.call.timed_out": return "timeout"
        default:
            switch status {
            case "rejected": return "rejected"
            case "canceled": return "canceled"
            case "ended": return "remote_hangup"
            case "timed_out": return "timeout"
            default: return ""
            }
        }
    }

    private func rtcBusyMessage(reasonCode: String, fallback: String? = nil) -> String {
        switch reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "duplicate_call":
            return "已有进行中的语音呼叫，请勿重复发起"
        case "caller_busy":
            return "你正在通话中，请结束后再试"
        case "callee_busy":
            return "对方正在通话中"
        default:
            let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "语音通话忙线，请稍后再试" : trimmed
        }
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    @discardableResult
    func refreshRTCCallsSilently() async -> RTCRefreshResult {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        return await refreshRTCCallsSilently(context: context, scope: scope)
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
    @discardableResult
    func refreshRTCCallsSilently(
        context: IMAPIContext,
        scope: String,
        allowBackgroundExecution: Bool = false
    ) async -> RTCRefreshResult {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return .skipped }
        guard !Task.isCancelled else { return .cancelled }
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else {
            voiceDebug("calls_refresh_skip context=\(Self.rtcDebugContextSummary(context)) scope_current=\(isCurrentRemoteScope(scope))")
            return .skipped
        }
        guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            voiceDebug("calls_refresh_skip gate=background context=\(Self.rtcDebugContextSummary(context))")
            return .skipped
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        if let inFlightScope = rtcCallsRefreshInFlightScope,
           inFlightScope == scope {
            voiceDebug("calls_refresh_skip gate=in_flight context=\(Self.rtcDebugContextSummary(context))")
            return .skipped
        }
        rtcCallsRefreshInFlightScope = scope
        defer {
            if rtcCallsRefreshInFlightScope == scope {
                rtcCallsRefreshInFlightScope = nil
            }
            schedulePendingRTCSignalingRefresh()
        }
        retryDuePendingRTCTerminalCompensations(reason: "calls_refresh")
        let observedLifecycleSnapshot = callStore.activeLifecycleSnapshot
        do {
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log RTC request attempts around lock/unlock without changing request payload.
            voiceDebug(
                "request_interface path=/api/rtc/calls backgrounded=\(isApplicationBackgroundedForRTC) allow_background=\(allowBackgroundExecution) context=\(Self.rtcDebugContextSummary(context))"
            )
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
            let calls = try await api.listRTCCalls(context: context)
            guard !Task.isCancelled,
                  isCurrentRemoteScope(scope),
                  allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
                voiceDebug("calls_refresh_discard scope_changed count=\(calls.count)")
                return .cancelled
            }
            voiceDebug("calls_refresh_ok http=2xx count=\(calls.count) statuses=\(Self.rtcStatusCountsSummary(calls.map(\.status))) context=\(Self.rtcDebugContextSummary(context))")
            reconcileRTCCalls(calls, observedLifecycleSnapshot: observedLifecycleSnapshot)
            return .success
        } catch {
            guard isCurrentRemoteScope(scope) else { return .cancelled }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            voiceDebug("calls_refresh_failed error=\(Self.safeVoiceErrorSummary(error))")
            logSyncEndpointFailure("/api/rtc/calls", error: error)
            return .failed(error)
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    private func reconcileRTCCalls(
        _ remoteCalls: [RemoteRTCCall],
        observedLifecycleSnapshot: CallLifecycleSnapshot? = nil
    ) {
        let identities = currentUserIdentitySet()
        voiceDebug("calls_reconcile_start count=\(remoteCalls.count) identities=\(Self.rtcIdentitySummary(identities)) active=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) incoming=\(Self.shortDebugID(incomingVoiceCall?.callID ?? ""))")
        remoteCalls.forEach { call in
            let reason = incomingRingingSkipReason(for: call, identities: identities) ?? "incoming_match"
            voiceDebug("calls_reconcile_item call=\(Self.shortDebugID(call.id)) status=\(call.status.lowercased()) caller=\(Self.shortDebugID(call.callerUID)) callee=\(Self.shortDebugID(call.calleeUID)) room=\(Self.shortDebugID(call.roomID)) reason=\(reason)")
        }
        let lifecycleItems = remoteCalls.map { call -> CallLifecycleReconciliationItem in
            let status = call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let phase: CallLifecyclePhase
            switch status {
            case "ringing": phase = .ringing
            case "accepted": phase = .dialing
            case "busy": phase = .busy
            case "rejected": phase = .rejected
            case "canceled", "cancelled": phase = .cancelled
            case "timed_out", "timeout": phase = .timeout
            case "ended": phase = .ended
            case "failed", "failure": phase = .failure
            default: phase = callStore.activeLifecycleSnapshot?.phase ?? .dialing
            }
            return CallLifecycleReconciliationItem(
                callID: call.id,
                phase: phase,
                revision: call.stateVersion,
                reason: call.endReason
            )
        }
        if let transition = callStore.reconcileLifecycle(
            observedSnapshot: observedLifecycleSnapshot,
            remoteCalls: lifecycleItems
        ) {
            renderCallLifecycleTransition(transition)
            if transition.isApplied,
               let releasedCallID = transition.current?.identity.callID,
               !remoteCalls.contains(where: { $0.id == releasedCallID }) {
                finishVoiceCallFromRemote(
                    status: "已结束",
                    subtitle: "语音通话 · 状态已同步",
                    toastText: "通话已结束",
                    endReason: "authoritative_reconciliation_absent",
                    expectedCallID: releasedCallID,
                    lifecyclePhase: .ended,
                    lifecycleAlreadyApplied: true
                )
                return
            }
        }
        remoteCalls.forEach { call in
            let normalizedStatus = call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["rejected", "canceled", "ended", "timed_out"].contains(normalizedStatus),
                  rtcTerminalMarkersByCallID[call.id] != nil else {
                return
            }
            refineTerminalMarkerAndRecord(
                callID: call.id,
                reason: call.endReason.isEmpty ? rtcTerminalReasonForStatus(normalizedStatus) : call.endReason,
                stateVersion: call.stateVersion,
                historicalTiming: rtcHistoricalCallTiming(call)
            )
        }
        // The list request can predate create/accept/join. Recheck current local
        // setup and resource ownership before treating its result as an orphan.
        if observedLifecycleSnapshot == nil,
           activeVoiceCall == nil,
           incomingVoiceCall == nil,
           !isStartingVoiceCall,
           !isStartingVideoCall,
           let orphanedOutgoingRinging = remoteCalls.first(where: {
               directCallResourceOwners[normalizedDirectCallID($0.id)] == nil
                   && outgoingRingingRTCCallBelongsToCurrentDevice($0, identities: identities)
           }) {
            terminateUnsupportedColdLaunchOutgoingRingingCall(orphanedOutgoingRinging)
            return
        }
        if observedLifecycleSnapshot == nil,
           activeVoiceCall == nil,
           incomingVoiceCall == nil,
           !isStartingVoiceCall,
           !isStartingVideoCall,
           let orphanedAccepted = remoteCalls.first(where: {
               directCallResourceOwners[normalizedDirectCallID($0.id)] == nil
                   && acceptedRTCCallBelongsToCurrentDeviceButCannotResume($0, identities: identities)
           }) {
            terminateUnsupportedColdLaunchAcceptedCall(orphanedAccepted)
            return
        }
        let incomingRinging = remoteCalls.first { call in
            isIncomingRingingRTCCall(call, identities: identities)
        }
        let currentCallID = activeVoiceCall?.callID ?? incomingVoiceCall?.callID ?? ""
        if !currentCallID.isEmpty,
           let matched = remoteCalls.first(where: { $0.id == currentCallID }) {
            refreshVoiceCallPeerIfBetter(voiceCallPeer(from: matched, identities: identities), matching: matched.id)
            reconcileVideoAudioDowngradeIfNeeded(from: matched)
            switch matched.status.lowercased() {
            case "accepted":
                if acceptedRTCCallWasAnsweredOnAnotherLocalDevice(
                    matched,
                    identities: identities
                ) {
                    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: avoid ending the call while this device is accepting.
                    if shouldDeferAcceptedElsewhereWhileAnswering(callID: matched.id) {
                        voiceDebug("calls_reconcile_current issue=connect_drop call=\(Self.shortDebugID(matched.id)) action=answered_elsewhere_deferred")
                        return
                    }
                    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END
                    voiceDebug("calls_reconcile_current call=\(Self.shortDebugID(matched.id)) action=answered_elsewhere")
                    finishVoiceCallFromRemote(
                        status: "已在其他设备接听",
                        subtitle: "语音通话 · 已在其他设备接听",
                        toastText: "已在其他设备接听",
                        endReason: "answered_elsewhere",
                        stateVersion: matched.stateVersion,
                        expectedCallID: matched.id,
                        lifecyclePhase: .ended
                    )
                    return
                }
                voiceDebug("calls_reconcile_current call=\(Self.shortDebugID(matched.id)) action=accepted_start_media")
                if activeVoiceCall?.requiresAcceptedDeviceBeforeJoin != true { cancelVoiceCallWatchdog() }
                SystemNotificationSound.setOutgoingRingbackSuppressed(true)
                SystemNotificationSound.stopAllCallPrompts()
                handleVoiceMediaEvent(.callAccepted, callID: matched.id)
                startVoiceMediaSessionFromActiveCall(
                    scope: remoteDataScopeKey(for: apiContext),
                    authoritativeCall: matched
                )
            case "rejected":
                voiceDebug("calls_reconcile_current call=\(Self.shortDebugID(matched.id)) action=terminal_rejected")
                finishVoiceCallFromRemote(
                    status: "已拒绝",
                    subtitle: "语音通话 · 对方已拒绝",
                    toastText: "对方已拒绝语音通话",
                    endReason: matched.endReason.isEmpty ? "rejected" : matched.endReason,
                    stateVersion: matched.stateVersion,
                    expectedCallID: matched.id,
                    lifecyclePhase: .rejected,
                    requiresAuthoritativeRevision: true,
                    historicalTiming: rtcHistoricalCallTiming(matched)
                )
            case "canceled":
                voiceDebug("calls_reconcile_current call=\(Self.shortDebugID(matched.id)) action=terminal_canceled")
                finishVoiceCallFromRemote(
                    status: "已取消",
                    subtitle: "语音通话 · 已取消",
                    toastText: "语音通话已取消",
                    endReason: matched.endReason.isEmpty ? "canceled" : matched.endReason,
                    stateVersion: matched.stateVersion,
                    expectedCallID: matched.id,
                    lifecyclePhase: .cancelled,
                    requiresAuthoritativeRevision: true,
                    historicalTiming: rtcHistoricalCallTiming(matched)
                )
            case "ended":
                voiceDebug("calls_reconcile_current call=\(Self.shortDebugID(matched.id)) action=terminal_ended")
                finishVoiceCallFromRemote(
                    status: "已结束",
                    subtitle: "语音通话 · 通话已结束",
                    toastText: "语音通话已结束",
                    endReason: matched.endReason.isEmpty ? "remote_hangup" : matched.endReason,
                    stateVersion: matched.stateVersion,
                    expectedCallID: matched.id,
                    lifecyclePhase: .ended,
                    requiresAuthoritativeRevision: true,
                    historicalTiming: rtcHistoricalCallTiming(matched)
                )
            case "timed_out":
                voiceDebug("calls_reconcile_current call=\(Self.shortDebugID(matched.id)) action=terminal_timed_out")
                finishVoiceCallFromRemote(
                    status: "未接通",
                    subtitle: "语音通话 · 已超时",
                    toastText: "语音通话已超时",
                    endReason: matched.endReason.isEmpty ? "timeout" : matched.endReason,
                    stateVersion: matched.stateVersion,
                    expectedCallID: matched.id,
                    lifecyclePhase: .timeout,
                    requiresAuthoritativeRevision: true,
                    historicalTiming: rtcHistoricalCallTiming(matched)
                )
            default:
                break
            }
        }
        guard activeVoiceCall == nil, incomingVoiceCall == nil else {
            voiceDebug("calls_reconcile_no_incoming reason=busy active=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) incoming=\(Self.shortDebugID(incomingVoiceCall?.callID ?? ""))")
            return
        }
        guard let ringing = incomingRinging else {
            voiceDebug("calls_reconcile_no_incoming reason=no_matching_ringing")
            return
        }
        voiceDebug("calls_reconcile_incoming_match call=\(Self.shortDebugID(ringing.id)) caller=\(Self.shortDebugID(ringing.callerUID)) room=\(Self.shortDebugID(ringing.roomID))")
        let peer = voiceCallPeer(from: ringing, identities: identities)
        receiveIncomingVoiceCall(
            from: peer,
            callID: ringing.id,
            roomID: ringing.roomID,
            mediaMode: ringing.requestedMediaMode,
            stateVersion: ringing.stateVersion,
            systemOwnsRingtone: voiceCallSystem.hasPresentedCall(callID: ringing.id)
        )
        voiceDebug("calls_reconcile_incoming_set call=\(Self.shortDebugID(incomingVoiceCall?.callID ?? "")) caller=\(Self.shortDebugID(incomingVoiceCall?.caller.id ?? ""))")
    }

    private func reconcileVideoAudioDowngradeIfNeeded(from remoteCall: RemoteRTCCall) {
        let normalizedMode = remoteCall.mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMode == "audio",
              var call = activeVoiceCall,
              call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == remoteCall.id,
              call.mediaMode == "video" else {
            return
        }
        applyVideoAudioDowngrade(to: &call)
        activeVoiceCall = call
        updateRTCMediaStateHeartbeat(rtcMediaStateForHeartbeat(call))
        Task { [videoMediaClient] in
            try? await videoMediaClient.downgradeToAudio()
        }
    }

    private func acceptedRTCCallBelongsToCurrentDeviceButCannotResume(
        _ call: RemoteRTCCall,
        identities: Set<String>
    ) -> Bool {
        guard call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "accepted" else {
            return false
        }
        let currentDeviceID = apiContext.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentDeviceID.isEmpty else { return false }
        if call.acceptedDevice?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) == currentDeviceID {
            return true
        }
        return identities.contains(call.callerUID.trimmingCharacters(in: .whitespacesAndNewlines))
            && call.callerDevice?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) == currentDeviceID
    }

    private func acceptedRTCCallWasAnsweredOnAnotherLocalDevice(
        _ call: RemoteRTCCall,
        identities: Set<String>
    ) -> Bool {
        let calleeUID = call.calleeUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDeviceID = apiContext.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptedDeviceID = call.acceptedDevice?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard identities.contains(calleeUID),
              !currentDeviceID.isEmpty,
              !acceptedDeviceID.isEmpty else {
            return false
        }
        return acceptedDeviceID != currentDeviceID
    }

    private func outgoingRingingRTCCallBelongsToCurrentDevice(
        _ call: RemoteRTCCall,
        identities: Set<String>
    ) -> Bool {
        guard call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ringing" else {
            return false
        }
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let callerUID = call.callerUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDeviceID = apiContext.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty,
              rtcTerminalMarkersByCallID[callID] == nil,
              identities.contains(callerUID),
              !currentDeviceID.isEmpty else {
            return false
        }
        return call.callerDevice?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines) == currentDeviceID
    }

    private func terminateUnsupportedColdLaunchOutgoingRingingCall(_ call: RemoteRTCCall) {
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = apiContext
        guard !callID.isEmpty,
              context.hasIMSession,
              coldLaunchUnsupportedCallIDs.insert(callID).inserted else { return }
        rtcTerminalMarkersByCallID[callID] = RTCCallTerminalMarker(
            callID: callID,
            reason: "client_restart_outgoing_ringing",
            stateVersion: call.stateVersion
        )
        voiceCallSystem.endCall(callID: callID, reason: "client_restart_outgoing_ringing")
        releaseCallLifecycle(as: .cancelled, reason: "client_restart_outgoing_ringing")
        toast = call.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
            ? "视频呼叫因应用重启已安全取消"
            : "语音呼叫因应用重启已安全取消"
        enqueueRTCTerminalCompensation(
            callID: callID,
            action: .cancel,
            reason: "client_restart_outgoing_ringing",
            context: context
        )
    }

    private func terminateUnsupportedColdLaunchAcceptedCall(_ call: RemoteRTCCall) {
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = apiContext
        guard !callID.isEmpty,
              context.hasIMSession,
              coldLaunchUnsupportedCallIDs.insert(callID).inserted else { return }
        rtcTerminalMarkersByCallID[callID] = RTCCallTerminalMarker(
            callID: callID,
            reason: "client_restart_media_resume_unsupported",
            stateVersion: call.stateVersion
        )
        voiceCallSystem.endCall(callID: callID, reason: "client_restart_media_resume_unsupported")
        releaseCallLifecycle(as: .failure, reason: "client_restart_media_resume_unsupported")
        toast = call.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
            ? "视频通话因应用重启已安全结束"
            : "语音通话因应用重启已安全结束"
        enqueueRTCTerminalCompensation(
            callID: callID,
            action: .hangup,
            reason: "client_restart_media_resume_unsupported",
            context: context
        )
    }

    private func rtcTerminalReasonForStatus(_ status: String) -> String {
        switch status {
        case "rejected": return "rejected"
        case "canceled": return "canceled"
        case "ended": return "remote_hangup"
        case "timed_out": return "timeout"
        default: return ""
        }
    }

    private func isIncomingRingingRTCCall(_ call: RemoteRTCCall, identities: Set<String>) -> Bool {
        incomingRingingSkipReason(for: call, identities: identities) == nil
    }

    private func incomingRingingSkipReason(for call: RemoteRTCCall, identities: Set<String>) -> String? {
        let status = call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "ringing" else { return "status_\(status.isEmpty ? "empty" : status)" }
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty,
              rtcTerminalMarkersByCallID[callID] == nil else {
            return callID.isEmpty ? "empty_call_id" : "terminal_marker"
        }
        let callerUID = call.callerUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callerUID.isEmpty,
              !identities.contains(callerUID) else { return callerUID.isEmpty ? "empty_caller" : "caller_is_self" }
        let calleeUID = call.calleeUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard calleeUID.isEmpty || identities.contains(calleeUID) else { return "callee_not_self" }
        return nil
    }

    #if DEBUG
    func handleVoiceCallSystemEventForTesting(_ event: VoiceCallSystemEvent) {
        handleVoiceCallSystemEvent(event)
    }

    var pendingRTCTerminalCompensationCountForTesting: Int {
        pendingRTCTerminalCompensations.count
    }

    var rtcTerminalCompensationsInFlightCountForTesting: Int {
        rtcTerminalCompensationsInFlight.count
    }

    func retryPendingRTCTerminalCompensationsForTesting() {
        retryPendingRTCTerminalCompensations()
    }

    func clearRTCTerminalCompensationsForTesting() {
        clearRTCTerminalCompensationsForScopeReset()
    }

    func reconcileActiveVideoAudioSessionForTesting(reason: String = "test") {
        reconcileActiveVideoAudioSession(reason: reason)
    }

    func refreshRTCCallEventsForTesting() async {
        await refreshRTCCallEventsSilently()
    }

    func refreshRTCCallsForTesting() async {
        await refreshRTCCallsSilently()
    }

    func reconcileRTCCallsForTesting(_ remoteCalls: [RemoteRTCCall]) {
        reconcileRTCCalls(remoteCalls, observedLifecycleSnapshot: callStore.activeLifecycleSnapshot)
    }

    func refreshRTCSignalingUsingCurrentContextForTesting() async {
        await refreshRTCSignalingUsingCurrentContext()
    }
    #endif

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    @discardableResult
    func refreshRTCCallEventsSilently() async -> RTCRefreshResult {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        return await refreshRTCCallEventsSilently(context: context, scope: scope)
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
    @discardableResult
    func refreshRTCCallEventsSilently(
        context: IMAPIContext,
        scope: String,
        allowBackgroundExecution: Bool = false
    ) async -> RTCRefreshResult {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return .skipped }
        guard !Task.isCancelled else { return .cancelled }
        guard context.hasIMSession,
              isCurrentRemoteScope(scope) else {
            voiceDebug("events_refresh_skip context=\(Self.rtcDebugContextSummary(context)) scope_current=\(isCurrentRemoteScope(scope))")
            return .skipped
        }
        guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            voiceDebug("events_refresh_skip gate=background context=\(Self.rtcDebugContextSummary(context))")
            return .skipped
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        if let inFlightScope = rtcEventsRefreshInFlightScope,
           inFlightScope == scope {
            voiceDebug("events_refresh_skip gate=in_flight context=\(Self.rtcDebugContextSummary(context))")
            return .skipped
        }
        rtcEventsRefreshInFlightScope = scope
        defer {
            if rtcEventsRefreshInFlightScope == scope {
                rtcEventsRefreshInFlightScope = nil
            }
            schedulePendingRTCSignalingRefresh()
        }
        do {
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log RTC request attempts around lock/unlock without changing request payload.
            voiceDebug(
                "request_interface path=/api/rtc/calls/events backgrounded=\(isApplicationBackgroundedForRTC) allow_background=\(allowBackgroundExecution) context=\(Self.rtcDebugContextSummary(context))"
            )
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
            let events = try await api.listRTCCallEvents(context: context)
            guard !Task.isCancelled,
                  isCurrentRemoteScope(scope),
                  allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
                voiceDebug("events_refresh_discard scope_changed count=\(events.count)")
                return .cancelled
            }
            voiceDebug("events_refresh_ok http=2xx count=\(events.count) types=\(Self.rtcStatusCountsSummary(events.map(\.type))) context=\(Self.rtcDebugContextSummary(context))")
            var processedNotificationIDs: [String] = []
            for event in events {
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
                guard !Task.isCancelled,
                      isCurrentRemoteScope(scope),
                      allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
                // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
                let envelope = RealtimeEnvelope(type: event.type, requestID: nil, payload: event.payload)
                if handleRTCCallEvent(envelope, scope: scope), !event.notificationID.isEmpty {
                    processedNotificationIDs.append(event.notificationID)
                }
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            if !processedNotificationIDs.isEmpty,
               isCurrentRemoteScope(scope),
               allowBackgroundExecution || !isApplicationBackgroundedForRTC {
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
                try? await api.ackRTCCallEventNotifications(
                    context: context,
                    notificationIDs: processedNotificationIDs
                )
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            return .success
        } catch {
            guard isCurrentRemoteScope(scope) else { return .cancelled }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            voiceDebug("events_refresh_failed error=\(Self.safeVoiceErrorSummary(error))")
            logSyncEndpointFailure("/api/rtc/calls/events", error: error)
            return .failed(error)
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    private struct RTCHistoricalCallTiming {
        var startedAt: Date?
        var endedAt: Date?
        var durationSeconds: TimeInterval?

        static let unknown = RTCHistoricalCallTiming()
    }

    private func rtcHistoricalCallTiming(_ call: RemoteRTCCall) -> RTCHistoricalCallTiming {
        rtcHistoricalCallTiming(payload: [
            "started_at": .string(call.startedAt),
            "accepted_at": .string(call.acceptedAt),
            "ended_at": .string(call.endedAt)
        ], callPayload: [:])
    }

    private func rtcHistoricalCallTiming(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> RTCHistoricalCallTiming {
        // Only server event times enter history. Neither delivery time nor the
        // local media clock is a substitute for missing server fields.
        func field(_ key: String) -> JSONValue? { callPayload[key] ?? payload[key] }
        func date(_ value: JSONValue?) -> (Date?, Bool) {
            guard let value else { return (nil, true) }
            if case .null = value { return (nil, true) }
            guard case .string(let raw) = value else { return (nil, false) }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, true) }
            let parsed = RTCCallRecordTimeProjection.parseServerTimestamp(raw)
            return (parsed, parsed != nil)
        }
        let (started, validStart) = date(field("started_at"))
        let (answered, validAnswer) = date(field("answered_at") ?? field("accepted_at"))
        let (connected, validMedia) = date(field("media_connected_at"))
        let (ended, validEnd) = date(field("ended_at"))
        guard validStart, validAnswer, validMedia, validEnd else { return .unknown }
        let timeline = [started, answered, connected, ended].compactMap { $0 }
        guard zip(timeline, timeline.dropFirst()).allSatisfy({ $0 <= $1 }) else { return .unknown }

        var duration: TimeInterval?
        if let supplied = field("duration_seconds"), supplied != .null {
            let seconds: Int?
            switch supplied {
            case .int(let value): seconds = value
            case .double(let value): seconds = value.isFinite ? Int(exactly: value) : nil
            case .string(let value): seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            default: seconds = nil
            }
            guard let seconds, seconds >= 0 else { return .unknown }
            // Positive duration requires media connection; signaling answer or
            // ringing alone must never manufacture a connected duration.
            if ended != nil, seconds == 0 || connected != nil {
                duration = TimeInterval(seconds)
            }
        } else if let connected, let ended {
            duration = floor(ended.timeIntervalSince(connected))
        }
        return RTCHistoricalCallTiming(startedAt: started, endedAt: ended, durationSeconds: duration)
    }

    private func finishVoiceCallFromRemote(
        status: String,
        subtitle: String,
        toastText: String,
        endReason: String = "",
        stateVersion: Int64 = 0,
        mediaAlreadyStopped: Bool = false,
        expectedCallID: String? = nil,
        lifecyclePhase: CallLifecyclePhase = .ended,
        requiresAuthoritativeRevision: Bool = false,
        lifecycleAlreadyApplied: Bool = false,
        historicalTiming: RTCHistoricalCallTiming = .unknown
    ) {
        let currentCallID = (activeVoiceCall?.callID ?? incomingVoiceCall?.callID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpectedCallID = expectedCallID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? currentCallID
        guard !normalizedExpectedCallID.isEmpty,
              currentCallID == normalizedExpectedCallID else {
            voiceDebug("call_finish_ignore reason=identity_mismatch expected=\(Self.shortDebugID(normalizedExpectedCallID)) current=\(Self.shortDebugID(currentCallID))")
            return
        }
        if !lifecycleAlreadyApplied, callStore.activeLifecycleSnapshot != nil {
            let accepted = advanceCallLifecycle(
                callID: normalizedExpectedCallID,
                to: lifecyclePhase,
                stateVersion: requiresAuthoritativeRevision ? stateVersion : nil,
                reason: endReason.isEmpty ? lifecyclePhase.rawValue : endReason
            )
            guard accepted else {
                voiceDebug("call_finish_ignore reason=lifecycle_rejected call=\(Self.shortDebugID(normalizedExpectedCallID)) phase=\(lifecyclePhase.rawValue) version=\(stateVersion)")
                return
            }
        }
        cancelVoiceCallWatchdog()
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        let peer = activeVoiceCall?.peer ?? incomingVoiceCall?.caller
        let activeCall = activeVoiceCall
        let isVideoCall = activeCall?.isVideoCall == true || incomingVoiceCall?.isVideo == true
        let normalizedSubtitle = isVideoCall
            ? subtitle.replacingOccurrences(of: "语音通话", with: "视频通话")
            : subtitle
        let normalizedToastText = isVideoCall
            ? toastText.replacingOccurrences(of: "语音通话", with: "视频通话")
            : toastText
        let systemCallID = activeVoiceCall?.callID ?? incomingVoiceCall?.callID
        let normalizedCallID = systemCallID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedEndReason = endReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCallID.isEmpty, !normalizedEndReason.isEmpty {
            rtcTerminalMarkersByCallID[normalizedCallID] = RTCCallTerminalMarker(
                callID: normalizedCallID,
                reason: normalizedEndReason,
                stateVersion: max(0, stateVersion)
            )
        }
        if let peer {
            let direction = currentVoiceCallRecordDirection()
            upsertVoiceCallRecord(
                callID: systemCallID,
                title: peer.name,
                subtitle: normalizedVoiceCallRecordSubtitle(normalizedSubtitle, direction: direction),
                status: status,
                direction: direction,
                peer: peer,
                startedAt: historicalTiming.startedAt,
                endedAt: historicalTiming.endedAt,
                durationSeconds: historicalTiming.durationSeconds,
                endReason: normalizedEndReason,
                stateVersion: stateVersion,
                replaceHistoricalTiming: true
            )
        }
        if let callID = systemCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callID.isEmpty {
            voiceCallSystem.endCall(callID: callID, reason: status)
            voipPushPayloadsByCallID.removeValue(forKey: callID)
        }
        if mediaAlreadyStopped, !normalizedCallID.isEmpty {
            stoppedVideoMediaCallIDs.insert(normalizedCallID)
            videoMediaEventTask?.cancel()
            videoMediaEventTask = nil
            activeVideoMediaCallID = nil
        } else {
            stopCallMediaSession(for: activeCall, reason: "remote_ended")
        }
        if let callID = systemCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callID.isEmpty {
            rtcPeerWaitTerminationCallIDs.remove(callID)
            releaseDirectCallTracking(callID: callID)
        }
        activeVoiceCall = nil
        incomingVoiceCall = nil
        if isVideoCall, let peer {
            presentVideoCallTerminal(
                callID: normalizedCallID,
                peer: peer,
                reason: normalizedEndReason.isEmpty ? normalizedToastText : normalizedEndReason,
                fallback: status,
                connectedAt: activeCall?.connectedAt,
                endedAt: Date() // Transient terminal presentation only; never persisted above.
            )
        }
        releaseAudioSessionForVoiceCall()
        // JHT_MOD_BEGIN RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改开始：远端/轮询终态后静默补拉对应私聊消息
        if !isVideoCall {
            syncRTCCallRecordConversationAfterTerminalIfPossible(
                channelID: nil,
                peer: peer,
                peerUID: nil,
                phase: lifecyclePhase,
                reason: normalizedEndReason.isEmpty ? lifecyclePhase.rawValue : normalizedEndReason
            )
        }
        // JHT_MOD_END RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改结束
        toast = normalizedToastText
    }

    private func upsertVoiceCallRecord(
        callID: String?,
        title: String,
        subtitle: String,
        status: String,
        direction: CallRecordDirection,
        peer: IMUser? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        endReason: String = "",
        stateVersion: Int64 = 0,
        replaceHistoricalTiming: Bool = false
    ) {
        ensureCallRecordPersistenceBindingIfNeeded()
        let normalizedCallID = callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingIndex: Int?
        if !normalizedCallID.isEmpty {
            existingIndex = calls.firstIndex { $0.callID == normalizedCallID }
        } else {
            existingIndex = calls.firstIndex {
                $0.title == title
                    && $0.direction == direction
                    && ["呼叫中", "来电中", "通话中"].contains($0.status)
            }
        }
        let existing = existingIndex.map { calls[$0] }
        let existingID = existingIndex.map { calls[$0].id } ?? "call_record_\(UUID().uuidString)"
        let normalizedPeerID = peer?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerUserID = peer?.userID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarURL = peer?.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarVersion = peer?.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarUpdatedAt = peer?.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarSource = voiceCallAvatarSource(for: peer)
        let resolvedStartedAt = replaceHistoricalTiming ? startedAt : (startedAt ?? existing?.startedAt)
        let resolvedEndedAt = replaceHistoricalTiming ? endedAt : (endedAt ?? existing?.endedAt)
        let resolvedDurationSeconds = replaceHistoricalTiming ? durationSeconds : (durationSeconds ?? existing?.durationSeconds)
        let normalizedEndReason = endReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEndReason = normalizedEndReason.isEmpty ? (existing?.endReason ?? "") : normalizedEndReason
        let resolvedStateVersion = max(existing?.stateVersion ?? 0, stateVersion)
        let next = CallRecord(
            id: existingID,
            callID: normalizedCallID.isEmpty ? nil : normalizedCallID,
            peerID: normalizedPeerID.isEmpty ? (existing?.peerID ?? "") : normalizedPeerID,
            peerUserID: normalizedPeerUserID.isEmpty ? (existing?.peerUserID ?? "") : normalizedPeerUserID,
            peerAvatarURL: normalizedPeerAvatarURL.isEmpty ? (existing?.peerAvatarURL ?? "") : normalizedPeerAvatarURL,
            peerAvatarVersion: normalizedPeerAvatarVersion.isEmpty ? (existing?.peerAvatarVersion ?? "") : normalizedPeerAvatarVersion,
            peerAvatarUpdatedAt: normalizedPeerAvatarUpdatedAt.isEmpty ? (existing?.peerAvatarUpdatedAt ?? "") : normalizedPeerAvatarUpdatedAt,
            peerAvatarSource: normalizedPeerAvatarSource.isEmpty ? (existing?.peerAvatarSource ?? "") : normalizedPeerAvatarSource,
            title: title,
            subtitle: subtitle,
            time: voiceCallRecordDisplayTime(startedAt: resolvedStartedAt, endedAt: resolvedEndedAt, existingTime: replaceHistoricalTiming ? "时间未知" : existing?.time),
            status: status,
            direction: direction,
            callType: voiceCallRecordType(subtitle: subtitle, existing: existing),
            startedAt: resolvedStartedAt,
            endedAt: resolvedEndedAt,
            durationSeconds: resolvedDurationSeconds,
            endReason: resolvedEndReason,
            stateVersion: resolvedStateVersion
        )
        if let existingIndex {
            calls.remove(at: existingIndex)
        }
        calls.insert(next, at: 0)
        let seen = Set(calls.compactMap(\.callID))
        guard !seen.isEmpty else { return }
        var retained: [CallRecord] = []
        var retainedCallIDs: Set<String> = []
        for record in calls {
            if let callID = record.callID, !callID.isEmpty {
                guard !retainedCallIDs.contains(callID) else { continue }
                retainedCallIDs.insert(callID)
            }
            retained.append(record)
        }
        calls = Array(retained.prefix(20))
    }

    private func voiceCallRecordType(subtitle: String, existing: CallRecord?) -> String {
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubtitle.hasPrefix("视频") {
            return "视频通话"
        }
        if trimmedSubtitle.hasPrefix("语音") {
            return "语音通话"
        }
        let existingType = existing?.callType.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return existingType.isEmpty ? "语音通话" : existingType
    }

    private func refineTerminalMarkerAndRecord(
        callID: String,
        reason: String,
        stateVersion: Int64,
        historicalTiming: RTCHistoricalCallTiming = .unknown
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              !normalizedReason.isEmpty,
              var marker = rtcTerminalMarkersByCallID[normalizedCallID] else {
            return
        }
        let normalizedVersion = max(0, stateVersion)
        if marker.stateVersion > 0, normalizedVersion == 0 { return }
        if normalizedVersion > 0, normalizedVersion < marker.stateVersion { return }
        guard let index = calls.firstIndex(where: { $0.callID == normalizedCallID }) else { return }
        let existing = calls[index]
        let canRefineTiming = existing.endedAt == nil && historicalTiming.endedAt != nil
        guard marker.reason == "server_signal_terminal" || canRefineTiming else { return }
        if marker.reason == "server_signal_terminal" { marker.reason = normalizedReason }
        marker.stateVersion = max(marker.stateVersion, normalizedVersion)
        rtcTerminalMarkersByCallID[normalizedCallID] = marker
        calls[index] = CallRecord(
            id: existing.id,
            callID: existing.callID,
            peerID: existing.peerID,
            peerUserID: existing.peerUserID,
            peerAvatarURL: existing.peerAvatarURL,
            peerAvatarVersion: existing.peerAvatarVersion,
            peerAvatarUpdatedAt: existing.peerAvatarUpdatedAt,
            peerAvatarSource: existing.peerAvatarSource,
            title: existing.title,
            subtitle: existing.subtitle,
            time: canRefineTiming
                ? voiceCallRecordDisplayTime(startedAt: historicalTiming.startedAt, endedAt: historicalTiming.endedAt, existingTime: "时间未知")
                : existing.time,
            status: existing.status,
            direction: existing.direction,
            callType: existing.callType,
            startedAt: canRefineTiming ? historicalTiming.startedAt : existing.startedAt,
            endedAt: canRefineTiming ? historicalTiming.endedAt : existing.endedAt,
            durationSeconds: canRefineTiming ? historicalTiming.durationSeconds : existing.durationSeconds,
            endReason: marker.reason,
            stateVersion: marker.stateVersion
        )
    }

    private func voiceCallRecordDisplayTime(startedAt: Date?, endedAt: Date?, existingTime: String?) -> String {
        if let endedAt {
            return displayTime(endedAt)
        }
        if let startedAt {
            return displayTime(startedAt)
        }
        let fallback = existingTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "刚刚" : fallback
    }

    private func voiceCallDurationSeconds(for call: VoiceCallSession, endedAt: Date, finalStatus: String) -> TimeInterval {
        guard finalStatus.contains("结束") || call.statusText == "通话中" else { return 0 }
        guard let connectedAt = call.connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }

    private func currentVoiceCallRecordDirection() -> CallRecordDirection {
        if activeVoiceCall?.direction == "来电" || incomingVoiceCall != nil {
            return .incoming
        }
        return .outgoing
    }

    private func normalizedVoiceCallRecordSubtitle(_ subtitle: String, direction: CallRecordDirection) -> String {
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard direction == .incoming || direction == .outgoing else { return trimmed }
        if trimmed.hasPrefix("语音来电")
            || trimmed.hasPrefix("语音呼出")
            || trimmed.hasPrefix("视频来电")
            || trimmed.hasPrefix("视频呼出") {
            return trimmed
        }
        let callKind = trimmed.hasPrefix("视频") ? "视频" : "语音"
        let prefix = direction == .incoming ? "\(callKind)来电" : "\(callKind)呼出"
        if let suffix = trimmed.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suffix.isEmpty,
           suffix != trimmed {
            return "\(prefix) · \(suffix)"
        }
        return trimmed.isEmpty ? prefix : "\(prefix) · \(trimmed)"
    }

    private func refreshVoiceCallPeerIfBetter(_ peer: IMUser, matching callID: String?) {
        refreshIncomingVoiceCallCallerIfBetter(peer, matching: callID)
        refreshActiveVoiceCallPeerIfBetter(peer, matching: callID)
    }

    private func refreshIncomingVoiceCallCallerIfBetter(_ caller: IMUser, matching callID: String?) {
        guard var call = incomingVoiceCall,
              voiceCallID(call.callID, matches: callID) else { return }
        let mergedCaller = voiceCallUser(merging: call.caller, with: caller)
        guard shouldReplaceVoiceCallUser(call.caller, with: mergedCaller, allowIdentityMismatch: true) else { return }
        call.caller = mergedCaller
        if (call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            call.callID = callID?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        incomingVoiceCall = call
    }

    private func refreshActiveVoiceCallPeerIfBetter(_ peer: IMUser, matching callID: String?) {
        guard var call = activeVoiceCall,
              voiceCallID(call.callID, matches: callID) else { return }
        let mergedPeer = voiceCallUser(merging: call.peer, with: peer)
        guard shouldReplaceVoiceCallUser(call.peer, with: mergedPeer, allowIdentityMismatch: true) else { return }
        call.peer = mergedPeer
        activeVoiceCall = call
    }

    private func voiceCallID(_ existing: String?, matches candidate: String?) -> Bool {
        let normalizedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedCandidate.isEmpty else { return true }
        return existing?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCandidate
    }

    private func shouldReplaceVoiceCallUser(_ existing: IMUser, with candidate: IMUser, allowIdentityMismatch: Bool = false) -> Bool {
        let sameIdentity = !Set(userIdentityCandidates(for: existing)).isDisjoint(with: Set(userIdentityCandidates(for: candidate)))
        guard sameIdentity || allowIdentityMismatch else { return false }
        if voiceCallUserLooksGeneric(existing), !voiceCallUserLooksGeneric(candidate) {
            return true
        }
        guard sameIdentity else { return false }
        if existing.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !candidate.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           candidate.avatarURL != existing.avatarURL {
            return true
        }
        if existing.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !candidate.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           candidate.avatarVersion != existing.avatarVersion {
            return true
        }
        if existing.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !candidate.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           candidate.avatarUpdatedAt != existing.avatarUpdatedAt {
            return true
        }
        return false
    }

    private func voiceCallUserLooksGeneric(_ user: IMUser) -> Bool {
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "语音联系人" { return true }
        return userIdentityCandidates(for: user).contains(name)
    }

    func displayUserForVoiceCall(_ user: IMUser) -> IMUser {
        userIdentityCandidates(for: user).reduce(user) { best, identifier in
            let candidate = userForVoiceCall(uid: identifier)
            let merged = voiceCallUser(merging: best, with: candidate)
            return shouldReplaceVoiceCallUser(best, with: merged) ? merged : best
        }
    }

    private func voiceCallChannelID(for user: IMUser, requestedChannelID: String?) -> String {
        let requested = requestedChannelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requested.isEmpty {
            return requested
        }
        if let conversation = directConversationForVoiceCall(uid: user.id, channelID: nil)
            ?? directConversationForVoiceCall(uid: user.userID, channelID: nil) {
            return remoteChannelID(for: conversation)
        }
        let currentID = (apiContext.imUID?.isEmpty == false ? apiContext.imUID : currentUser.id) ?? currentUser.id
        let peerID = user.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentID.isEmpty, !peerID.isEmpty, currentID != peerID else { return "" }
        return [currentID, canonicalDirectParticipantID(peerID)].filter { !$0.isEmpty }.sorted().joined(separator: ":")
    }

    private func userForVoiceCall(uid: String, channelID: String? = nil) -> IMUser {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let user = contacts.first(where: { voiceCallUser($0, matches: trimmed) }) {
            return user
        }
        for conversation in conversations {
            if let user = conversation.participants.first(where: { voiceCallUser($0, matches: trimmed) }) {
                return user
            }
        }
        if let conversation = directConversationForVoiceCall(uid: trimmed, channelID: channelID) {
            return voiceCallUser(from: conversation, fallbackUID: trimmed)
        }
        return IMUser(
            id: trimmed.isEmpty ? "unknown_voice_peer" : trimmed,
            userID: trimmed,
            name: trimmed.isEmpty ? "语音联系人" : trimmed,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(trimmed),
            badges: []
        )
    }

    private func directConversationForVoiceCall(uid: String, channelID: String?) -> Conversation? {
        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentIDs = currentUserIdentitySet()
        let channelPeerIDs = Set(directChannelParts(trimmedChannelID).filter { !currentIDs.contains($0) })
        return conversations.first { conversation in
            guard conversation.kind == .direct else { return false }
            if !trimmedUID.isEmpty, directPeerID(for: conversation) == trimmedUID {
                return true
            }
            let conversationParts = Set((directChannelParts(conversation.id) + directChannelParts(remoteChannelID(for: conversation))).filter { !$0.isEmpty })
            if !trimmedUID.isEmpty, conversationParts.contains(trimmedUID) {
                return true
            }
            guard !channelPeerIDs.isEmpty else { return false }
            let conversationPeerIDs = conversationParts.filter { !currentIDs.contains($0) }
            return !conversationPeerIDs.isEmpty && !conversationPeerIDs.isDisjoint(with: channelPeerIDs)
        }
    }

    private func voiceCallUser(from conversation: Conversation, fallbackUID: String) -> IMUser {
        let trimmedFallback = fallbackUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIDs = currentUserIdentitySet()
        let peerID = directPeerID(for: conversation)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? directChannelParts(remoteChannelID(for: conversation)).first(where: { !currentIDs.contains($0) })
            ?? directChannelParts(conversation.id).first(where: { !currentIDs.contains($0) })
            ?? trimmedFallback
        if let user = contacts.first(where: { voiceCallUser($0, matches: peerID) }) {
            return user
        }
        if let user = conversation.participants.first(where: { voiceCallUser($0, matches: peerID) }) {
            return user
        }
        let resolvedID = peerID.isEmpty ? (trimmedFallback.isEmpty ? "unknown_voice_peer" : trimmedFallback) : peerID
        let displayName = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return IMUser(
            id: resolvedID,
            userID: resolvedID,
            name: displayName.isEmpty ? (resolvedID == "unknown_voice_peer" ? "语音联系人" : resolvedID) : displayName,
            title: "",
            department: "",
            phone: "",
            email: "",
            status: "在线",
            enterprise: currentEnterprise.name,
            avatarSeed: stableSeed(resolvedID),
            avatarURL: conversation.avatarURL,
            avatarVersion: conversation.avatarVersion,
            avatarUpdatedAt: conversation.avatarUpdatedAt,
            badges: []
        )
    }

    private func voiceCallUser(_ user: IMUser, matches rawIdentifier: String) -> Bool {
        let normalized = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return userIdentityCandidates(for: user).contains(normalized)
    }

    private enum VoiceCallPeerRole {
        case caller
        case callee
    }

    private func voiceCallPeer(from call: RemoteRTCCall, identities: Set<String>) -> IMUser {
        let callerIsSelf = identities.contains(call.callerUID.trimmingCharacters(in: .whitespacesAndNewlines))
        let role: VoiceCallPeerRole = callerIsSelf ? .callee : .caller
        let peerUID = callerIsSelf ? call.calleeUID : call.callerUID
        let base = userForVoiceCall(uid: peerUID, channelID: call.channelID)
        let profile = role == .caller ? call.callerProfile : call.calleeProfile
        return voiceCallUser(
            merging: base,
            uid: profile?.uid ?? peerUID,
            userID: profile?.userID ?? "",
            displayName: role == .caller ? call.callerName : call.calleeName,
            avatarURL: role == .caller ? call.callerAvatarURL : call.calleeAvatarURL,
            avatarVersion: role == .caller ? call.callerAvatarVersion : call.calleeAvatarVersion,
            avatarUpdatedAt: role == .caller ? call.callerAvatarUpdatedAt : call.calleeAvatarUpdatedAt
        )
    }

    private func voiceCallPeer(
        from payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        peerUID: String,
        peerRole: VoiceCallPeerRole,
        channelID: String
    ) -> IMUser {
        let profile = rtcProfile(from: payload, callPayload: callPayload, role: peerRole)
        let base = userForVoiceCall(uid: peerUID, channelID: channelID)
        return voiceCallUser(
            merging: base,
            uid: profile?.uid ?? peerUID,
            userID: profile?.userID ?? "",
            displayName: profile?.displayName ?? flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .name),
            avatarURL: flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .avatar, fallback: profile?.avatar ?? ""),
            avatarVersion: flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .avatarVersion, fallback: profile?.avatarVersion ?? ""),
            avatarUpdatedAt: flatRTCProfileString(from: payload, callPayload: callPayload, role: peerRole, field: .avatarUpdatedAt, fallback: profile?.avatarUpdatedAt ?? "")
        )
    }

    private enum RTCProfileFlatField {
        case name
        case avatar
        case avatarVersion
        case avatarUpdatedAt
    }

    private func rtcProfile(
        from payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        role: VoiceCallPeerRole
    ) -> RemoteRTCParticipantProfile? {
        let nestedKeys: [String] = role == .caller
            ? ["caller_profile", "callerProfile", "caller", "from_profile"]
            : ["callee_profile", "calleeProfile", "callee", "target_profile"]
        for key in nestedKeys {
            if let object = payload[key]?.objectValue ?? callPayload[key]?.objectValue {
                let profile = RemoteRTCParticipantProfile(
                    uid: payloadString(object, ["uid", "im_uid", "imUID", "id"]),
                    userID: payloadString(object, ["user_id", "userID", "userId"]),
                    displayName: payloadString(object, ["display_name", "displayName", "nickname", "name", "username"]),
                    avatar: payloadString(object, ["avatar", "avatar_url", "avatarURL", "avatarUrl"]),
                    avatarVersion: payloadString(object, ["avatar_version", "avatarVersion", "version"]),
                    avatarUpdatedAt: payloadString(object, ["avatar_updated_at", "avatarUpdatedAt", "updated_at", "updatedAt"])
                )
                if !profile.isEmpty {
                    return profile
                }
            }
        }
        return nil
    }

    private func flatRTCProfileString(
        from payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        role: VoiceCallPeerRole,
        field: RTCProfileFlatField,
        fallback: String = ""
    ) -> String {
        let keys: [String]
        switch (role, field) {
        case (.caller, .name):
            keys = ["caller_name", "callerName", "from_name", "fromName"]
        case (.callee, .name):
            keys = ["callee_name", "calleeName", "target_name", "targetName"]
        case (.caller, .avatar):
            keys = ["caller_avatar", "caller_avatar_url", "callerAvatar", "callerAvatarUrl", "from_avatar", "fromAvatar"]
        case (.callee, .avatar):
            keys = ["callee_avatar", "callee_avatar_url", "calleeAvatar", "calleeAvatarUrl", "target_avatar", "target_avatar_url", "targetAvatar", "targetAvatarUrl"]
        case (.caller, .avatarVersion):
            keys = ["caller_avatar_version", "callerAvatarVersion", "from_avatar_version", "fromAvatarVersion"]
        case (.callee, .avatarVersion):
            keys = ["callee_avatar_version", "calleeAvatarVersion", "target_avatar_version", "targetAvatarVersion"]
        case (.caller, .avatarUpdatedAt):
            keys = ["caller_avatar_updated_at", "callerAvatarUpdatedAt", "from_avatar_updated_at", "fromAvatarUpdatedAt"]
        case (.callee, .avatarUpdatedAt):
            keys = ["callee_avatar_updated_at", "calleeAvatarUpdatedAt", "target_avatar_updated_at", "targetAvatarUpdatedAt"]
        }
        let value = payloadString(payload, keys, fallback: payloadString(callPayload, keys))
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    private func voiceCallUser(merging base: IMUser, with candidate: IMUser) -> IMUser {
        voiceCallUser(
            merging: base,
            uid: candidate.id,
            userID: candidate.userID,
            username: candidate.username,
            displayName: candidate.name,
            avatarURL: candidate.avatarURL,
            avatarVersion: candidate.avatarVersion,
            avatarUpdatedAt: candidate.avatarUpdatedAt
        )
    }

    private func voiceCallUser(
        merging base: IMUser,
        uid: String,
        userID: String,
        username: String = "",
        displayName: String,
        avatarURL: String,
        avatarVersion: String,
        avatarUpdatedAt: String
    ) -> IMUser {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseLooksGeneric = voiceCallUserLooksGeneric(base)
        let resolvedID = baseLooksGeneric && !normalizedUID.isEmpty ? normalizedUID : (base.id.isEmpty ? normalizedUID : base.id)
        let nextName: String
        if baseLooksGeneric,
           !normalizedName.isEmpty,
           !isIdentifierLikeDisplayName(normalizedName, matching: resolvedID) {
            nextName = normalizedName
        } else {
            nextName = base.name
        }

        let resolvedAvatar = resolvedVoiceCallAvatarURL(avatarURL)
        let baseAvatar = base.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAvatar = resolvedAvatar.isEmpty ? base.avatarURL : resolvedAvatar
        let incomingVersion = avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingUpdatedAt = avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextVersion: String
        if resolvedAvatar.isEmpty {
            nextVersion = base.avatarVersion
        } else if !incomingVersion.isEmpty {
            nextVersion = incomingVersion
        } else {
            nextVersion = resolvedAvatar == baseAvatar ? base.avatarVersion : ""
        }
        let nextUpdatedAt: String
        if resolvedAvatar.isEmpty {
            nextUpdatedAt = base.avatarUpdatedAt
        } else if !incomingUpdatedAt.isEmpty {
            nextUpdatedAt = incomingUpdatedAt
        } else {
            nextUpdatedAt = resolvedAvatar == baseAvatar ? base.avatarUpdatedAt : ""
        }

        return IMUser(
            id: resolvedID.isEmpty ? base.id : resolvedID,
            userID: normalizedUserID.isEmpty ? base.userID : normalizedUserID,
            username: normalizedUsername.isEmpty ? base.username : normalizedUsername,
            name: nextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (resolvedID.isEmpty ? "语音联系人" : resolvedID) : nextName,
            title: base.title,
            department: base.department,
            departmentPathNames: base.departmentPathNames,
            phone: base.phone,
            phoneVerified: base.phoneVerified,
            realNameVerified: base.realNameVerified,
            realNameStatus: base.realNameStatus,
            email: base.email,
            status: base.status,
            enterprise: base.enterprise,
            avatarSeed: base.avatarSeed == 0 ? stableSeed(resolvedID) : base.avatarSeed,
            avatarURL: nextAvatar,
            avatarVersion: nextVersion,
            avatarUpdatedAt: nextUpdatedAt,
            badges: base.badges
        )
    }

    private func resolvedVoiceCallAvatarURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return resolveTenantAssetURL(trimmed)
    }

    private func voiceCallAvatarSource(for peer: IMUser?) -> String {
        guard let peer else { return "" }
        let avatar = peer.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !avatar.isEmpty else { return "" }
        let identities = Set(userIdentityCandidates(for: peer))
        if contacts.contains(where: { contact in
            !Set(userIdentityCandidates(for: contact)).isDisjoint(with: identities)
                && contact.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) == avatar
        }) {
            return "contact"
        }
        if conversations.contains(where: { conversation in
            conversation.participants.contains { participant in
                !Set(userIdentityCandidates(for: participant)).isDisjoint(with: identities)
                    && participant.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) == avatar
            } || (conversation.kind == .direct
                && conversation.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) == avatar)
        }) {
            return "conversation"
        }
        return "rtc_payload"
    }

}

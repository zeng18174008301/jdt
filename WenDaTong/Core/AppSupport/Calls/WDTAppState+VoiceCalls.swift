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
    var hasTruthfulCallOwnership: Bool {
        callStore.hasTruthfulCall
    }

    func renderCallLifecycleTransition(_ transition: CallLifecycleTransition?) {
        guard let transition else { return }
        SystemNotificationSound.render(callStore.promptCommands(for: transition))
    }

    func renderCallPromptEnvironment(_ event: CallPromptEnvironmentEvent) {
        SystemNotificationSound.render(callStore.promptCommands(for: event))
    }

    @discardableResult
    func claimCallLifecycle(
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
    func advanceCallLifecycle(
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

    func discardUnownedLegacyCallViews(reason: String) {
        guard !hasTruthfulCallOwnership,
              activeVoiceCall != nil || incomingVoiceCall != nil else { return }
        voiceDebug("call_view_discard reason=\(reason)")
        stopCallMediaSession(for: activeVoiceCall, reason: reason)
        activeVoiceCall = nil
        incomingVoiceCall = nil
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopAllCallPrompts()
    }

    func releaseAbandonedCallOwnershipBeforeIncoming(callID: String) {
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
    func reconcileActiveCallAudioSession(reason: String) {
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ self.setToast(reason == "media_services_reset"
                        ? "视频通话音频服务恢复失败，请结束后重试"
                        : "视频通话音频路由恢复失败") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ self.setToast(reason == "media_services_reset"
                    ? "语音通话音频服务恢复失败，请结束后重试"
                    : "语音通话音频路由恢复失败") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
            }
        }
    }

    func reconcileActiveVideoAudioSession(reason: String) {
        reconcileActiveCallAudioSession(reason: reason)
    }
    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束

    func directCallCapabilityGeneration(for kind: DirectCallCapabilityKind) -> UInt64 {
        directCallCapabilityGenerations[kind, default: 0]
    }

    func currentDirectCallAttempt(for kind: DirectCallCapabilityKind) -> DirectCallAttempt? {
        directCallAttempts[kind]
    }

    func clearCurrentDirectCallAttempt(
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

    func beginDirectCallAttempt(
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

    func rebindDirectCallAttempt(
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

    func normalizedDirectCallID(_ callID: String) -> String {
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

    func currentDirectCallRequestContext(
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

    func directCallCleanupContext(_ stored: IMAPIContext) -> IMAPIContext {
        let current = apiContext
        guard current.hasIMSession,
              DirectCallContextBinding(context: current) == DirectCallContextBinding(context: stored) else {
            return stored
        }
        return current
    }
    // WDT_RTC_IOS1_AUTODROP_20260921_END

    func registerAcceptedDirectCallCleanupObligation(
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

    func resolveDirectCallCleanupObligations(
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

    func releaseDirectCallTracking(callID: String) {
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

    func directCallResourceIsOwned(
        callID: String,
        by attempt: DirectCallAttempt
    ) -> Bool {
        let callID = normalizedDirectCallID(callID)
        return !callID.isEmpty && directCallResourceOwners[callID] == attempt
    }

    func clearActiveDirectCallResourceIfOwned(
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

    func hangupDirectCallResourceIfOwned(
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

    func ensureDirectCallAttemptIsCurrent(_ attempt: DirectCallAttempt) throws {
        guard isCurrentDirectCallAttempt(attempt) else {
            throw CancellationError()
        }
    }

    func awaitDirectCallStage<Value>(
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

    func finishDirectCallAttemptSetup(_ attempt: DirectCallAttempt) {
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

    func directCallAttemptForActiveCall(_ call: VoiceCallSession) -> DirectCallAttempt? {
        let kind: DirectCallCapabilityKind = call.isVideoCall ? .video : .voice
        guard let attempt = currentDirectCallAttempt(for: kind),
              activeCallMatchesDirectCallAttempt(attempt) else {
            return nil
        }
        return attempt
    }

}

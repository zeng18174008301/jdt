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
    func enqueueRTCTerminalCompensation(
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
    func stableRTCTerminalMutationIdempotencyKey(
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

    func enqueueRTCTerminalCompensationAfterInitialFailure(
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

    func clearRTCTerminalCompensationIfMatches(
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

    func retryPendingRTCTerminalCompensations(callID: String? = nil) {
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        retryDuePendingRTCTerminalCompensations(callID: callID, reason: "compat")
    }

    func retryDuePendingRTCTerminalCompensations(
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

    func makeRTCTerminalCompensationIdempotencyKey(action: RTCTerminalCompensationAction) -> String {
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

    func rejectCompetingIncomingCallIfPossible(
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

    func rejectPresentedIncomingCallForAdmissionFailure(callID: String, reason: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        rejectCompetingIncomingCallIfPossible(callID: normalizedCallID, reason: reason)
    }

    func rollbackFailedSystemAnswer(
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

}

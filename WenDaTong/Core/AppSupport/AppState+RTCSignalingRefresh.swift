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
    func startRTCCallRefreshLoop() {
        stopRTCCallRefreshLoop()
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return }
        guard let startupContext = currentRTCSignalingRefreshContext(reason: "loop_start") else { return }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        resetRTCDiscoveryBackoff()
        let refreshGeneration = rtcRefreshGeneration
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        voiceDebug("refresh_loop_start context=\(Self.rtcDebugContextSummary(startupContext.context))")
        rtcSignalingRefreshPendingScope = startupContext.scope
        rtcCallRefreshTask = Task { [weak self] in
            await self?.refreshRTCSignalingUsingCurrentContext(
                requiresPendingWakeup: true,
                generation: refreshGeneration
            )
            while !Task.isCancelled {
                let interval = await MainActor.run { [weak self] () -> UInt64 in
                    guard let self else { return 20_000_000_000 }
                    return self.rtcRefreshLoopIntervalNanoseconds()
                }
                await MainActor.run { [weak self] in
                    self?.voiceDebug(routine: true, "refresh_loop_tick interval_ms=\(interval / 1_000_000)")
                }
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self?.refreshRTCSignalingUsingCurrentContext(generation: refreshGeneration)
            }
        }
    }

    func stopRTCCallRefreshLoop() {
        if rtcCallRefreshTask != nil {
            voiceDebug("refresh_loop_stop")
        }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        rtcRefreshGeneration &+= 1
        resetRTCDiscoveryBackoff()
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        rtcCallRefreshTask?.cancel()
        rtcCallRefreshTask = nil
        rtcSignalingWakeTask?.cancel()
        rtcSignalingWakeTask = nil
        rtcSignalingWakeTaskID = nil
        rtcSignalingRefreshPendingScope = nil
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    private func resetRTCDiscoveryBackoff() {
        rtcDiscoveryCallsBackoff.reset()
        rtcDiscoveryEventsBackoff.reset()
    }

    private func rtcRefreshLoopIntervalNanoseconds() -> UInt64 {
        let baseInterval: UInt64
        if activeVoiceCall != nil
            || incomingVoiceCall != nil
            || isStartingVoiceCall
            || isStartingVideoCall {
            baseInterval = activeRTCCallRefreshIntervalNanoseconds
        } else {
            baseInterval = idleRTCCallRefreshIntervalNanoseconds
        }
        guard let backoffDelay = nextRTCDiscoveryBackoffDelayNanoseconds() else {
            return baseInterval
        }
        return max(baseInterval, backoffDelay)
    }

    private func nextRTCDiscoveryBackoffDelayNanoseconds() -> UInt64? {
        let now = rtcRequestNowNanoseconds()
        let endpointDelays = [
            rtcDiscoveryEventsBackoff.remainingDelayNanoseconds(nowNanoseconds: now),
            rtcDiscoveryCallsBackoff.remainingDelayNanoseconds(nowNanoseconds: now)
        ]
        guard endpointDelays.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return endpointDelays.compactMap { $0 }.min()
    }

    private func discoveryBackoffDelayNanoseconds(for endpoint: RTCRefreshEndpoint) -> UInt64? {
        let now = rtcRequestNowNanoseconds()
        switch endpoint {
        case .events:
            return rtcDiscoveryEventsBackoff.remainingDelayNanoseconds(nowNanoseconds: now)
        case .calls:
            return rtcDiscoveryCallsBackoff.remainingDelayNanoseconds(nowNanoseconds: now)
        }
    }

    private func recordRTCDiscoveryRefreshResult(_ result: RTCRefreshResult, endpoint: RTCRefreshEndpoint) {
        let now = rtcRequestNowNanoseconds()
        switch endpoint {
        case .events:
            rtcDiscoveryEventsBackoff.record(
                result,
                endpoint: endpoint,
                nowNanoseconds: now,
                delays: rtcDiscoveryFailureDelayNanoseconds
            )
        case .calls:
            rtcDiscoveryCallsBackoff.record(
                result,
                endpoint: endpoint,
                nowNanoseconds: now,
                delays: rtcDiscoveryFailureDelayNanoseconds
            )
        }
        if let error = result.failedError {
            voiceDebug("refresh_backoff_record endpoint=\(endpoint) error=\(Self.safeVoiceErrorSummary(error))")
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    private func currentRTCSignalingRefreshContext(reason: String) -> (context: IMAPIContext, scope: String)? {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard !isApplicationBackgroundedForRTC else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=background context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard isAuthenticated else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=not_authenticated context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        guard context.hasIMSession else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=no_im_session context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        guard isCurrentRemoteScope(scope) else {
            voiceDebug("refresh_context_skip reason=\(reason) gate=scope_mismatch context=\(Self.rtcDebugContextSummary(context))")
            return nil
        }
        return (context, scope)
    }

    func refreshRTCSignalingUsingCurrentContext(
        requiresPendingWakeup: Bool = false,
        generation: UInt64? = nil
    ) async {
        let snapshot = await MainActor.run { [weak self] in
            self?.currentRTCSignalingRefreshContext(reason: "loop_tick")
        }
        guard let snapshot else {
            await MainActor.run { [weak self] in
                self?.stopRTCCallRefreshLoop()
            }
            return
        }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        if let generation, rtcRefreshGeneration != generation {
            return
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        await refreshRTCSignalingSilently(
            context: snapshot.context,
            scope: snapshot.scope,
            requiresPendingWakeup: requiresPendingWakeup,
            generation: generation
        )
    }

    func ensureRTCSignalingRefreshActive(reason: String) {
        voiceDebug("refresh_loop_ensure reason=\(reason) active=\(rtcCallRefreshTask != nil) context=\(Self.rtcDebugContextSummary(apiContext))")
        guard let snapshot = currentRTCSignalingRefreshContext(reason: reason) else { return }
        if rtcCallRefreshTask == nil {
            startRTCCallRefreshLoop()
        }
        rtcSignalingRefreshPendingScope = snapshot.scope
        schedulePendingRTCSignalingRefresh()
    }

    func schedulePendingRTCSignalingRefresh() {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime,
              !isApplicationBackgroundedForRTC,
              let scope = rtcSignalingRefreshPendingScope,
              let snapshot = currentRTCSignalingRefreshContext(reason: "pending_wakeup"),
              snapshot.scope == scope,
              rtcSignalingWakeTask == nil,
              rtcSignalingRefreshInFlightScope != scope,
              rtcEventsRefreshInFlightScope != scope,
              rtcCallsRefreshInFlightScope != scope else { return }
        let operationID = UUID()
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        let generation = rtcRefreshGeneration
        let wakeDelay = nextRTCDiscoveryBackoffDelayNanoseconds()
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        rtcSignalingWakeTaskID = operationID
        rtcSignalingWakeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // A retired task must not clear a newer wakeup owner.
                if self.rtcSignalingWakeTaskID == operationID {
                    self.rtcSignalingWakeTask = nil
                    self.rtcSignalingWakeTaskID = nil
                    self.schedulePendingRTCSignalingRefresh()
                }
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            if let wakeDelay, wakeDelay > 0 {
                try? await self.rtcRequestSleep(wakeDelay)
            }
            guard self.rtcRefreshGeneration == generation,
                  !self.isApplicationBackgroundedForRTC else { return }
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            guard !Task.isCancelled,
                  self.isCurrentRemoteScope(scope),
                  self.rtcSignalingRefreshPendingScope == scope else { return }
            await self.refreshRTCSignalingSilently(
                context: snapshot.context,
                scope: scope,
                requiresPendingWakeup: true,
                generation: generation
            )
        }
    }

    @discardableResult
    func refreshRTCSignalingSilently(
        context: IMAPIContext,
        scope: String,
        requiresPendingWakeup: Bool = false,
        generation: UInt64? = nil,
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
        allowBackgroundExecution: Bool = false
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
    ) async -> RTCRefreshBatchResult {
        var result = RTCRefreshBatchResult()
        let sessionGeneration = localMessageSessionGeneration
        guard !Task.isCancelled,
              let runtimeScope = callRecordRuntimeScope(for: context),
              isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration),
              isCurrentRemoteScope(scope) else { return result }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            voiceDebug("refresh_signaling_skip gate=background context=\(Self.rtcDebugContextSummary(context))")
            return result
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        guard !requiresPendingWakeup || rtcSignalingRefreshPendingScope == scope else { return result }
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        if let generation, rtcRefreshGeneration != generation {
            return result
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        // Direct events-only and calls→events callers hold the real RPC slots too.
        // Keep the wake pending until all pre-existing reads have released them.
        guard rtcSignalingRefreshInFlightScope != scope,
              rtcEventsRefreshInFlightScope != scope,
              rtcCallsRefreshInFlightScope != scope else { return result }
        rtcSignalingRefreshInFlightScope = scope
        defer {
            if rtcSignalingRefreshInFlightScope == scope {
                rtcSignalingRefreshInFlightScope = nil
            }
            schedulePendingRTCSignalingRefresh()
        }
        if rtcSignalingRefreshPendingScope == scope {
            rtcSignalingRefreshPendingScope = nil
        }
        voiceDebug(routine: true, "refresh_signaling_start context=\(Self.rtcDebugContextSummary(context))")
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
        if let delay = discoveryBackoffDelayNanoseconds(for: .events) {
            voiceDebug("events_refresh_skip gate=backoff delay_ms=\(delay / 1_000_000)")
        } else {
            result.events = await refreshRTCCallEventsSilently(
                context: context,
                scope: scope,
                allowBackgroundExecution: allowBackgroundExecution
            )
            recordRTCDiscoveryRefreshResult(result.events, endpoint: .events)
        }
        guard !Task.isCancelled,
              isCurrentRemoteScope(scope),
              allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            result.events = .cancelled
            return result
        }
        guard isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration) else {
            result.calls = .cancelled
            return result
        }
        if let generation, rtcRefreshGeneration != generation {
            result.calls = .cancelled
            return result
        }
        if let delay = discoveryBackoffDelayNanoseconds(for: .calls) {
            voiceDebug("calls_refresh_skip gate=backoff delay_ms=\(delay / 1_000_000)")
        } else {
            result.calls = await refreshRTCCallsSilently(
                context: context,
                scope: scope,
                allowBackgroundExecution: allowBackgroundExecution
            )
            recordRTCDiscoveryRefreshResult(result.calls, endpoint: .calls)
        }
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
        voiceDebug(routine: true, "refresh_signaling_done context=\(Self.rtcDebugContextSummary(context))")
        return result
    }

}

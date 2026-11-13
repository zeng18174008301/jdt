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
        guard let runtimeScope = callRecordRuntimeScope(for: context),
              runtimeScope == callRecordRuntimeScope(for: apiContext),
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
        let sessionGeneration = localMessageSessionGeneration
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
                routine: true, "request_interface path=/api/rtc/calls backgrounded=\(isApplicationBackgroundedForRTC) allow_background=\(allowBackgroundExecution) context=\(Self.rtcDebugContextSummary(context))"
            )
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
            let calls = try await api.listRTCCalls(context: context)
            guard !Task.isCancelled,
                  isCurrentRemoteScope(scope),
                  isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration),
                  allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
                voiceDebug("calls_refresh_discard scope_changed count=\(calls.count)")
                return .cancelled
            }
            voiceDebug(routine: true, "calls_refresh_ok http=2xx count=\(calls.count) statuses=\(Self.rtcStatusCountsSummary(calls.map(\.status))) context=\(Self.rtcDebugContextSummary(context))")
            reconcileRTCCalls(calls, observedLifecycleSnapshot: observedLifecycleSnapshot)
            return .success
        } catch {
            guard isCurrentRemoteScope(scope),
                  isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration) else { return .cancelled }
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
        voiceDebug(routine: true, "calls_reconcile_start count=\(remoteCalls.count) identities=\(Self.rtcIdentitySummary(identities)) active=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) incoming=\(Self.shortDebugID(incomingVoiceCall?.callID ?? ""))")
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
            voiceDebug(routine: true, "calls_reconcile_no_incoming reason=busy active=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) incoming=\(Self.shortDebugID(incomingVoiceCall?.callID ?? ""))")
            return
        }
        guard let ringing = incomingRinging else {
            voiceDebug(routine: true, "calls_reconcile_no_incoming reason=no_matching_ringing")
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(call.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
            ? "视频呼叫因应用重启已安全取消"
            : "语音呼叫因应用重启已安全取消") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ setToast(call.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
            ? "视频通话因应用重启已安全结束"
            : "语音通话因应用重启已安全结束") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
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

}

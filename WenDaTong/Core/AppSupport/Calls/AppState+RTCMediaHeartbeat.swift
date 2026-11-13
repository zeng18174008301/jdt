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
    func startRTCMediaStateHeartbeat(
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

    func rtcMediaStateForHeartbeat(_ call: VoiceCallSession?) -> String {
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

    func updateRTCMediaStateHeartbeat(_ mediaState: String, force: Bool = false) {
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

    func renewRTCMediaStateHeartbeatNow(reason: String) {
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

    func isRTCMediaHeartbeatCurrent(_ session: RTCMediaHeartbeatSession) -> Bool {
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

}

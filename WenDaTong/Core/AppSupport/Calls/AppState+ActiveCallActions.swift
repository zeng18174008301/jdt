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
    func toggleActiveCallMuted() {
        let nextValue = !(activeVoiceCall?.isMuted ?? false)
        voiceDebug("ui_action_mute call=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) muted=\(nextValue)")
        setActiveVoiceCallMuted(nextValue, notifySystem: true)
    }

    func setActiveVoiceCallMuted(_ isMuted: Bool, notifySystem: Bool) {
        guard activeVoiceCall != nil else { return }
        guard isVoiceMediaClientAvailable else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(voiceMediaClientUnavailableReason)
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(voiceMediaClientUnavailableReason)
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("视频通话音频路由切换失败")
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

    func presentVideoCallTerminal(
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

    func applyVideoAudioDowngrade(to call: inout VoiceCallSession, preservingStatusText: String? = nil) {
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已取消视频通话")
                return
            }
            // JHT_MOD_END RTC_VIDEO_FAST_PRESENT_FROM_CHAT_20260912 - 修改结束
            activeCallEndError = "登录会话不可用，无法结束通话，请重新登录后重试"
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(activeCallEndError)
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
        // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_BEGIN
        ensureCallRecordPersistenceBindingIfNeeded()
        let rollbackLocalEndRecord = callStore.makeCallRecordRollback(callID: normalizedCallID)
        // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111_END
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("通话已结束，连接记录同步未确认")
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
                rollbackLocalEndRecord() // WDT_IOS1_CALL_ARCHIVE_BACKGROUND_20261111
                isEndingActiveCall = false
                activeCallEndError = "未能结束通话，请检查网络后重试"
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(activeCallEndError)
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("\(callKind)通话已结束")
    }

    // JHT_MOD_BEGIN RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改开始：只补同步已有私聊，不本地伪造通话消息
    func syncRTCCallRecordConversationAfterTerminalIfPossible(
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
                      self.conversationStore.conversationMessageSnapshots().contains(where: { $0.id == conversationID }) else { return }
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
    ) -> ConversationMessageSnapshot? {
        let normalizedChannelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerUID = peerUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let conversation = directConversationForVoiceCall(
            uid: normalizedPeerUID,
            channelID: normalizedChannelID
        ) {
            return conversation
        }
        if !normalizedChannelID.isEmpty,
           let conversation = conversationStore.conversationMessageSnapshots().first(where: {
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

    func stopCallMediaSession(for call: VoiceCallSession?, reason: String, preserveHeartbeat: Bool = false) {
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

    func ensureMicrophonePermissionForVoiceCall() async -> Bool {
        if let microphonePermissionDecisionOverride {
            return await microphonePermissionDecisionOverride()
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("麦克风权限未开启，请在系统设置中允许 问达通 使用麦克风")
            }
            return granted
        case .denied, .restricted:
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("麦克风权限未开启，请在系统设置中允许 问达通 使用麦克风")
            return false
        @unknown default:
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前设备无法使用麦克风")
            return false
        }
    }

    func configureAudioSessionForVoiceCall() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else {
            throw IMAPIError.server("当前设备无法使用麦克风")
        }
    }

    func releaseAudioSessionForVoiceCall() {
        SystemNotificationSound.stopAllCallPrompts()
    }

    func rtcCallFailureReason(for error: Error, defaultReason: String) -> String {
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

    func scheduleOutgoingVoiceCallWatchdog(callID: String, scope: String, timeoutSeconds: Int?) {
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

} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

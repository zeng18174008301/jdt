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
    func startVideoMediaSession(
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("视频设备信息不完整，请稍后重试")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("摄像头暂不可用，已关闭摄像头继续视频通话")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast(desired ? "摄像头开启失败，请稍后重试" : "摄像头关闭失败，请稍后重试")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("切换摄像头失败，已保留原摄像头")
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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("通话状态尚未同步，暂时无法切换为语音")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_BEGIN */ self.setToast(mediaSignalFailed
                    ? "已切换为语音通话，对端状态同步可能稍有延迟"
                    : "已切换为语音通话，当前通话无法恢复视频") /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110_END */
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
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前接口暂不支持切回视频，请重新发起视频通话")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ self.setToast("返回前台后摄像头恢复失败，已保持关闭")
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

    func awaitRTCMediaStage<Value>(
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

    func isCurrentRTCMediaOperation(_ operationID: UUID) -> Bool {
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

}

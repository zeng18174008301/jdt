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
    func startVoiceMediaSession(
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

    func startVoiceMediaSessionFromActiveCall(
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

    func joinedRoomReadyForVoiceStart(
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
    func waitForCallKitAudioSessionBeforeVoiceStart(
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

}

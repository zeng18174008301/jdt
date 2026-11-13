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
    func startOutgoingVoiceCall(to peer: IMUser? = nil, channelID: String? = nil) {
        guard guardCallLicenseForAction(.voice) else { return }
        guard !isStartingVoiceCall else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在发起语音通话，请稍候")
            return
        }
        discardUnownedLegacyCallViews(reason: "outgoing_voice_truth_reconcile")
        guard !hasTruthfulCallOwnership else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(incomingVoiceCall != nil ? "请先处理当前来电" : "当前正在通话中")
            return
        }
        guard let target = peer, !isCurrentUserProfile(target) else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(DirectConversationCallPeerResolver.unavailableMessage)
            return
        }
        if let reason = voiceCallUnavailableReason(for: target) {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            return
        }
        let scope = remoteDataScopeKey(for: context)
        var attempt = beginDirectCallAttempt(
            kind: .voice,
            context: context,
            peerID: target.id,
            mediaMode: "audio"
        )
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("正在发起语音通话")
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
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已发起语音通话")
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

    func initialOutgoingRoomJoin(
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
    func ensureRTCProviderReadyForAudioCall(
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

}

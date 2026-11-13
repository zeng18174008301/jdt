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
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(answerMode == "video" ? "正在视频接听，请稍候" : "正在语音接听，请稍候")
            return
        }
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("需要麦克风权限才能接听通话")
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
                    /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(notice)
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
    func ensureRTCProviderReadyForVideoCall(
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

    func requireVideoProviderCapabilities(_ provider: RemoteRTCProvider) throws {
        try requireRTCLicense(provider.videoCallEnabled, media: .video)
        guard provider.supportsVideo else {
            throw IMAPIError.server("对方版本或当前服务暂不支持视频通话")
        }
        guard provider.mediaPlaneConfigured, provider.iceServersConfigured else {
            throw IMAPIError.server("视频服务媒体配置缺失，请联系管理员")
        }
    }

    func ensureVideoPermission() async -> Bool {
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

}

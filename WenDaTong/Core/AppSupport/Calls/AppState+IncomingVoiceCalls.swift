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
    func receiveIncomingVoiceCall(
        from caller: IMUser,
        callID: String? = nil,
        roomID: String? = nil,
        mediaMode: String = "audio",
        stateVersion: Int64 = 0,
        systemOwnsRingtone: Bool = false
    ) {
        discardUnownedLegacyCallViews(reason: "incoming_truth_reconcile")
        let normalizedCallID = callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        releaseAbandonedCallOwnershipBeforeIncoming(callID: normalizedCallID)
        voiceDebug("incoming_receive_attempt call=\(Self.shortDebugID(callID ?? "")) caller=\(Self.shortDebugID(caller.id)) room=\(Self.shortDebugID(roomID ?? "")) active=\(Self.shortDebugID(activeVoiceCall?.callID ?? "")) existing=\(Self.shortDebugID(incomingVoiceCall?.callID ?? ""))")
        if let reason = incomingVoiceCallUnavailableReason(for: caller) {
            voiceDebug("incoming_receive_reject reason=policy message=\(reason)")
            rejectPresentedIncomingCallForAdmissionFailure(callID: normalizedCallID, reason: "policy_unavailable")
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
            return
        }
        let isVideo = mediaMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
        if isVideo, (!fileUploadConfig.videoCallEnabled || !videoMediaClient.isAvailable) {
            rejectPresentedIncomingCallForAdmissionFailure(callID: normalizedCallID, reason: "video_unavailable")
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(fileUploadConfig.videoCallEnabled ? videoMediaClientUnavailableReason : "当前企业未开通视频通话")
            return
        }
        guard !normalizedCallID.isEmpty else {
            voiceDebug("incoming_receive_reject reason=empty_call_id")
            return
        }
        guard rtcTerminalMarkersByCallID[normalizedCallID] == nil else {
            voiceDebug("incoming_receive_reject reason=terminal_marker call=\(Self.shortDebugID(normalizedCallID))")
            if voiceCallSystem.hasPresentedCall(callID: normalizedCallID) {
                voiceCallSystem.endCall(callID: normalizedCallID, reason: "terminal_marker")
            }
            return
        }
        if isVideo { videoCallTerminalResult = nil }
        if let incomingVoiceCall {
            let existingCallID = incomingVoiceCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nextCallID = normalizedCallID
            if !existingCallID.isEmpty, existingCallID == nextCallID {
                voiceDebug("incoming_receive_existing call=\(Self.shortDebugID(existingCallID)) action=refresh_caller")
                if systemOwnsRingtone {
                    SystemNotificationSound.setSystemOwnsIncomingRingtone(true)
                }
                refreshIncomingVoiceCallCallerIfBetter(caller, matching: nextCallID)
                // A delayed higher-authority state event may be the first event
                // that carries the requested video type. Apply monotonic
                // refinements without ever downgrading an already-known video
                // call to audio.
                if stateVersion >= incomingVoiceCall.stateVersion {
                    self.incomingVoiceCall?.stateVersion = max(incomingVoiceCall.stateVersion, stateVersion)
                    if isVideo {
                        self.incomingVoiceCall?.requestedMediaMode = "video"
                        self.incomingVoiceCall?.source = "好友视频通话"
                    }
                }
                return
            }
            voiceDebug("incoming_receive_reject reason=existing_incoming existing=\(Self.shortDebugID(existingCallID)) next=\(Self.shortDebugID(nextCallID))")
            rejectCompetingIncomingCallIfPossible(callID: nextCallID)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("请先处理当前来电")
            return
        }
        guard !hasTruthfulCallOwnership else {
            voiceDebug("incoming_receive_reject reason=active_call active=\(Self.shortDebugID(activeVoiceCall?.callID ?? ""))")
            rejectCompetingIncomingCallIfPossible(callID: normalizedCallID)
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("当前正在通话中")
            return
        }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(systemOwnsRingtone)
        guard claimCallLifecycle(
            callID: normalizedCallID,
            direction: .incoming,
            stateVersion: stateVersion,
            reason: "incoming_ringing"
        ) else { return }
        incomingVoiceCall = IncomingVoiceCall(
            id: "incoming_\(UUID().uuidString)",
            callID: callID,
            caller: caller,
            startedAt: "刚刚",
            source: isVideo ? "好友视频通话" : "好友语音通话"
            ,
            requestedMediaMode: isVideo ? "video" : "audio",
            stateVersion: stateVersion
        )
        voiceDebug("incoming_receive_set call=\(Self.shortDebugID(incomingVoiceCall?.callID ?? "")) caller=\(Self.shortDebugID(incomingVoiceCall?.caller.id ?? ""))")
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("\(caller.name) 正在呼叫你")
    }

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: complete acceptIncomingVoiceCall implementation, including all failure cleanup branches.
    func acceptIncomingVoiceCall(fromSystem: Bool = false) {
        guard let call = incomingVoiceCall, !call.isVideo else { return }
        guard incomingCallAnswerMode == nil else { return }
        let systemCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // WDT_IOS1_CALLKIT_ANSWER_20260921: both app UI and system UI share CallKit audio ownership.
        let usesSystemAudio = fromSystem || voiceCallSystem.hasPresentedCall(callID: systemCallID)
        guard guardCallLicenseForAction(.voice) else {
            if usesSystemAudio {
                rollbackFailedSystemAnswer(callID: systemCallID, context: apiContext,
                    reason: "callkit_answer_license_unavailable", rejectServer: true,
                    preservingEstablishedCall: true)
            }
            return
        }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        let context = apiContext
        guard context.hasIMSession else {
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("登录会话不可用，请重新登录")
            if usesSystemAudio {
                rollbackFailedSystemAnswer(
                    callID: systemCallID,
                    context: context,
                    reason: "callkit_answer_session_unavailable",
                    rejectServer: false
                )
            }
            return
        }
        let scope = remoteDataScopeKey(for: context)
        var attempt = beginDirectCallAttempt(
            kind: .voice,
            context: context,
            callID: call.callID ?? "",
            peerID: call.caller.id,
            mediaMode: "audio"
        )
        guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
        callStore.incomingCallAnswerOperationID = attempt.operationID
        incomingCallAnswerMode = "audio"
        Task {
            defer {
                if callStore.incomingCallAnswerOperationID == attempt.operationID {
                    callStore.incomingCallAnswerOperationID = nil
                    incomingCallAnswerMode = nil
                }
                finishDirectCallAttemptSetup(attempt)
            }
            var acceptedCallID: String?
            var acceptedCallContext = context
            var installedActiveCall = false
            do {
                try await ensureRTCProviderReadyForAudioCall(
                    context: context,
                    scope: scope,
                    attempt: attempt
                )
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
                let microphoneAuthorized = try await awaitDirectCallStage(attempt) {
                    await ensureMicrophonePermissionForVoiceCall()
                }
                guard microphoneAuthorized else {
                    if usesSystemAudio {
                        rollbackFailedSystemAnswer(
                            callID: systemCallID,
                            context: context,
                            reason: "callkit_answer_microphone_denied",
                            rejectServer: true
                        )
                    }
                    return
                }
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: answer the already-presented system call before media setup.
                if usesSystemAudio && !fromSystem {
                    try await awaitDirectCallStage(attempt) {
                        try await voiceCallSystem.answerPresentedCall(callID: systemCallID)
                    }
                }
                // WDT_IOS1_CALLKIT_ANSWER_20260921_END
                try configureAudioSessionForVoiceCall()
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else {
                    releaseAudioSessionForVoiceCall()
                    return
                }
                let response: RemoteRTCCallResponse?
                if let callID = call.callID, !callID.isEmpty {
                    response = try await awaitDirectCallStage(attempt) {
                        let requestContext = try currentDirectCallRequestContext(context, attempt: attempt)
                        acceptedCallContext = requestContext
                        return try await api.acceptRTCCall(context: requestContext, callID: callID)
                    }
                    acceptedCallID = response?.call.id.isEmpty == false ? response?.call.id : callID
                    attempt = try rebindDirectCallAttempt(
                        attempt,
                        callID: acceptedCallID
                    )
                    if let acceptedCallID {
                        registerAcceptedDirectCallCleanupObligation(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            attempt: attempt
                        )
                    }
                } else {
                    response = nil
                }
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else {
                    releaseAudioSessionForVoiceCall()
                    if let acceptedCallID, !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                var joinedRoom: RemoteRTCRoomJoinData?
                var acceptedRemoteCall: RemoteRTCCall?
                if let response {
                    guard !response.call.roomID.isEmpty,
                          !response.rtcToken.isEmpty else {
                        throw IMAPIError.server("语音房间信息不完整")
                    }
                    joinedRoom = try await awaitDirectCallStage(attempt) {
                        try await api.joinRTCRoom(
                            context: currentDirectCallRequestContext(acceptedCallContext, attempt: attempt),
                            roomID: response.call.roomID,
                            rtcToken: response.rtcToken
                        )
                    }
                    acceptedRemoteCall = rtcCall(response.call, withRTCToken: response.rtcToken)
                }
                guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else {
                    releaseAudioSessionForVoiceCall()
                    if let acceptedCallID, !acceptedCallID.isEmpty {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "client_scope_changed"
                        )
                    }
                    return
                }
                let lifecycleCallID = acceptedRemoteCall?.id.isEmpty == false
                    ? acceptedRemoteCall!.id
                    : (call.callID ?? "")
                _ = advanceCallLifecycle(
                    callID: lifecycleCallID,
                    to: .dialing,
                    stateVersion: (acceptedRemoteCall?.stateVersion ?? 0) > 0 ? acceptedRemoteCall?.stateVersion : nil,
                    reason: "incoming_answered_media_connecting"
                )
                activeVoiceCall = VoiceCallSession(
                    id: "call_\(UUID().uuidString)",
                    callID: acceptedRemoteCall?.id.isEmpty == false ? acceptedRemoteCall?.id : call.callID,
                    roomID: acceptedRemoteCall?.roomID ?? "",
                    rtcToken: response?.rtcToken ?? "",
                    mediaBaseURL: joinedRoom?.media.owtBaseURL ?? "",
                    peer: call.caller,
                    direction: "来电",
                    startedAt: call.startedAt,
                    statusText: "连接中",
                    mediaState: .preparing,
                    isMuted: false,
                    speakerOn: true,
                    startedAtDate: Date(),
                    connectedAt: nil
                )
                installedActiveCall = true
                incomingVoiceCall = nil
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(nil)
                if let acceptedRemoteCall, let joinedRoom {
                    let readyRoom = try await joinedRoomReadyForVoiceStart(
                        call: acceptedRemoteCall,
                        joinedRoom: joinedRoom,
                        context: acceptedCallContext,
                        roomID: acceptedRemoteCall.roomID,
                        rtcToken: response?.rtcToken ?? acceptedRemoteCall.rtcToken,
                        scope: scope,
                        attempt: attempt
                    )
                    guard isCurrentDirectCallAttempt(attempt),
                          directCallResourceIsOwned(callID: acceptedRemoteCall.id, by: attempt),
                          activeVoiceCall?.callID == acceptedRemoteCall.id else {
                        clearActiveDirectCallResourceIfOwned(
                            callID: acceptedRemoteCall.id,
                            by: attempt,
                            reason: "incoming_voice_scope_changed"
                        )
                        if let acceptedCallID, !acceptedCallID.isEmpty {
                            await hangupDirectCallResourceIfOwned(
                                context: acceptedCallContext,
                                callID: acceptedCallID,
                                by: attempt,
                                reason: "client_scope_changed"
                            )
                        }
                        return
                    }
                    if usesSystemAudio {
                        try await waitForCallKitAudioSessionBeforeVoiceStart(
                            callID: acceptedRemoteCall.id,
                            scope: scope,
                            attempt: attempt
                        )
                    }
                    startVoiceMediaSession(
                        call: acceptedRemoteCall,
                        joinedRoom: readyRoom,
                        direction: "来电",
                        peer: call.caller,
                        scope: scope,
                        attempt: attempt
                    )
                }
                resolveDirectCallCleanupObligations(for: attempt)
            } catch {
                if isCurrentDirectCallAttempt(attempt) || acceptedCallID.map({ directCallResourceIsOwned(callID: $0, by: attempt) }) == true {
                    releaseAudioSessionForVoiceCall()
                }
                if let waitError = error as? RTCPeerParticipantWaitError {
                    if waitError == .timedOut,
                       isCurrentDirectCallAttempt(attempt) {
                        if usesSystemAudio {
                            rollbackFailedSystemAnswer(
                                callID: acceptedCallID ?? systemCallID,
                                context: context,
                                reason: "callkit_answer_peer_timeout",
                                rejectServer: acceptedCallID == nil
                            )
                        }
                        return
                    }
                }
                guard isCurrentDirectCallAttempt(attempt) else {
                    if usesSystemAudio, acceptedCallID == nil {
                        rollbackUnconnectedSystemAnswerIfOwned(attempt: attempt, context: context)
                    }
                    if let acceptedCallID {
                        clearActiveDirectCallResourceIfOwned(
                            callID: acceptedCallID,
                            by: attempt,
                            reason: "incoming_voice_scope_changed"
                        )
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
                    guard let acceptedCallID,
                          directCallResourceIsOwned(callID: acceptedCallID, by: attempt),
                          activeVoiceCall?.callID == acceptedCallID else { return }
                } else {
                    guard isCurrentIncomingVoiceAnswer(call, attempt: attempt) else { return }
                }
                let failedLifecycleCallID = acceptedCallID ?? call.callID ?? ""
                _ = advanceCallLifecycle(
                    callID: failedLifecycleCallID,
                    to: .failure,
                    reason: "incoming_voice_setup_failed"
                )
                activeVoiceCall = nil
                incomingVoiceCall = nil
                if let acceptedCallID, !acceptedCallID.isEmpty {
                    let failureReason = rtcCallFailureReason(
                        for: error,
                        defaultReason: "network_error"
                    )
                    Task {
                        await hangupDirectCallResourceIfOwned(
                            context: acceptedCallContext,
                            callID: acceptedCallID,
                            by: attempt,
                            reason: failureReason
                        )
                    }
                }
                if usesSystemAudio {
                    rollbackFailedSystemAnswer(
                        callID: acceptedCallID ?? systemCallID,
                        context: context,
                        reason: "callkit_answer_setup_failed",
                        rejectServer: acceptedCallID == nil
                    )
                }
                handleRemoteError(error, fallback: "接听通话失败", rtcMedia: .voice)
            }
        }
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END: complete acceptIncomingVoiceCall implementation.

    private func isCurrentIncomingVoiceAnswer(
        _ expected: IncomingVoiceCall,
        attempt: DirectCallAttempt
    ) -> Bool {
        guard attempt.kind == .voice,
              isCurrentDirectCallAttempt(attempt),
              let current = incomingVoiceCall,
              !current.isVideo,
              current.id == expected.id,
              current.caller.id == attempt.peerID else {
            return false
        }
        let expectedCallID = expected.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentCallID = current.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return currentCallID == expectedCallID
            && currentCallID == attempt.callID
    }

    func rollbackUnconnectedSystemAnswerIfOwned(
        attempt: DirectCallAttempt,
        context: IMAPIContext
    ) {
        // Capability refresh may invalidate the attempt before its catch runs.
        // The UI may already be cleared by a successful license revocation.
        // Resource ownership survives capability invalidation, but is released
        // by explicit cancellation and replaced by a newer answer operation.
        guard DirectCallContextBinding(context: apiContext) == attempt.context,
              directCallResourceIsOwned(callID: attempt.callID, by: attempt) else { return }
        rollbackFailedSystemAnswer(
            callID: attempt.callID, context: context,
            reason: "callkit_answer_capability_changed", rejectServer: true,
            preservingEstablishedCall: true
        )
    }

    func declineIncomingVoiceCall() {
        guard let call = incomingVoiceCall else { return }
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        let normalizedCallID = call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedCallID.isEmpty {
            let context = apiContext
            if context.hasIMSession {
                enqueueRTCTerminalCompensation(
                    callID: normalizedCallID,
                    action: .reject,
                    reason: "local_reject",
                    context: context
                )
            }
            voiceCallSystem.endCall(callID: normalizedCallID, reason: "local_reject")
            voipPushPayloadsByCallID.removeValue(forKey: normalizedCallID)
            releaseDirectCallTracking(callID: normalizedCallID)
        }
        let now = Date()
        let callKind = call.isVideo ? "视频" : "语音"
        calls.insert(
            CallRecord(
                id: "call_record_\(UUID().uuidString)",
                callID: call.callID,
                peerID: call.caller.id,
                peerUserID: call.caller.userID,
                peerAvatarURL: call.caller.avatarURL,
                peerAvatarVersion: call.caller.avatarVersion,
                peerAvatarUpdatedAt: call.caller.avatarUpdatedAt,
                peerAvatarSource: voiceCallAvatarSource(for: call.caller),
                title: call.caller.name,
                subtitle: "\(callKind)来电 · 我已拒接",
                time: displayTime(now),
                status: "已拒接",
                direction: .incoming,
                callType: "\(callKind)通话",
                startedAt: now,
                endedAt: now,
                durationSeconds: 0
            ),
            at: 0
        )
        _ = advanceCallLifecycle(
            callID: normalizedCallID,
            to: .rejected,
            reason: "local_reject"
        )
        incomingVoiceCall = nil
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("已拒接\(callKind)通话")
    }

}

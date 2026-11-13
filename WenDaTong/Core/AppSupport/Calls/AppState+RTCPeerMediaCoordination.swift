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
    func markActiveCallWaitingForPeer(callID: String) {
        guard var call = activeVoiceCall,
              call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID.trimmingCharacters(in: .whitespacesAndNewlines),
              !isEndingActiveCall else { return }
        call.mediaState = .connecting
        call.statusText = "等待对方连接"
        activeVoiceCall = call
    }

    func markActiveCallPeerWaitFailed(callID: String) {
        guard var call = activeVoiceCall,
              call.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID.trimmingCharacters(in: .whitespacesAndNewlines),
              !isEndingActiveCall else { return }
        call.mediaState = .failed
        call.statusText = "连接失败"
        activeVoiceCall = call
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("连接失败，请结束后重试")
    }

    func terminateRTCCallAfterPeerWaitTimeout(
        call: RemoteRTCCall,
        context: IMAPIContext,
        scope: String,
        attempt: DirectCallAttempt? = nil
    ) async {
        if let attempt {
            guard isCurrentDirectCallAttempt(attempt) else { return }
        }
        let callID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty,
              isCurrentRemoteScope(scope),
              activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID,
              rtcPeerWaitTerminationCallIDs.insert(callID).inserted else {
            return
        }
        cancelVoiceCallWatchdog()
        stopCallMediaSession(for: activeVoiceCall, reason: "peer_participant_timeout")
        if pendingVoiceMediaJoinCallID == callID {
            pendingVoiceMediaJoinCallID = nil
        }
        releaseAudioSessionForVoiceCall()
        // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
        let terminalReason = "peer_participant_timeout"
        let terminalAction: RTCTerminalCompensationAction =
            call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ringing"
            ? .cancel
            : .hangup
        let idempotencyKey = stableRTCTerminalMutationIdempotencyKey(
            callID: callID,
            action: terminalAction,
            reason: terminalReason,
            context: context
        )
        // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
        do {
            let normalizedStatus = call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedStatus == "ringing" {
                try await api.cancelRTCCall(
                    context: context,
                    callID: callID,
                    reason: terminalReason,
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    idempotencyKey: idempotencyKey
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                )
            } else {
                try await api.hangupRTCCall(
                    context: context,
                    callID: callID,
                    reason: terminalReason,
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    idempotencyKey: idempotencyKey
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                )
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            clearRTCTerminalCompensationIfMatches(
                callID: callID,
                action: terminalAction,
                idempotencyKey: idempotencyKey
            )
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
            // Keep the failed call surface visible. The authoritative server resource
            // is ended exactly once above, while the user still receives a stable
            // failure state and may dismiss/retry without a disappearing screen.
            guard isCurrentRemoteScope(scope),
                  activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
                return
            }
            markActiveCallPeerWaitFailed(callID: callID)
        } catch {
            guard isCurrentRemoteScope(scope),
                  attempt.map(isCurrentDirectCallAttempt) ?? true,
                  activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
                return
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            enqueueRTCTerminalCompensationAfterInitialFailure(
                callID: callID,
                action: terminalAction,
                reason: terminalReason,
                context: context,
                idempotencyKey: idempotencyKey,
                error: error
            )
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("连接失败，结束通话失败，请重试")
        }
    }

    func normalizedJoinedRoom(
        _ joinedRoom: RemoteRTCRoomJoinData,
        call: RemoteRTCCall,
        context: IMAPIContext,
        roomID: String,
        rtcToken: String,
        participants extraParticipants: [RemoteRTCRoomParticipant] = []
    ) -> RemoteRTCRoomJoinData {
        let normalizedRoomID = joinedRoom.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? roomID : joinedRoom.roomID
        let normalizedToken = joinedRoom.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rtcToken : joinedRoom.rtcToken
        let selfUID = context.imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? currentUser.id
        let selfDeviceID = context.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        var participants = joinedRoom.participants
        for participant in extraParticipants {
            if !participants.contains(where: { $0.uid == participant.uid && $0.deviceID == participant.deviceID }) {
                participants.append(participant)
            }
        }
        let selfParticipant = joinedRoom.selfParticipant
            ?? participants.first { participant in
                let uid = participant.uid.trimmingCharacters(in: .whitespacesAndNewlines)
                let deviceID = participant.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
                return (!selfUID.isEmpty && uid == selfUID) || (!selfDeviceID.isEmpty && deviceID == selfDeviceID)
            }
            ?? RemoteRTCRoomParticipant(uid: selfUID, deviceID: selfDeviceID, deviceType: "ios", role: "self")
        if !participants.contains(where: { $0.uid == selfParticipant.uid && $0.deviceID == selfParticipant.deviceID }) {
            participants.append(selfParticipant)
        }
        let peerParticipant = resolvedRTCPeerParticipant(
            explicitPeer: joinedRoom.peerParticipant,
            call: call,
            selfParticipant: selfParticipant,
            participants: participants
        )
        if let peerParticipant,
           !participants.contains(where: { $0.uid == peerParticipant.uid && $0.deviceID == peerParticipant.deviceID }) {
            participants.append(peerParticipant)
        }
        return RemoteRTCRoomJoinData(
            roomID: normalizedRoomID,
            rtcToken: normalizedToken,
            media: joinedRoom.media,
            selfParticipant: selfParticipant,
            peerParticipant: peerParticipant,
            participants: participants
        )
    }

    func rtcCall(_ call: RemoteRTCCall, withRTCToken rtcToken: String) -> RemoteRTCCall {
        RemoteRTCCall(
            id: call.id,
            status: call.status,
            roomID: call.roomID,
            rtcToken: rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? call.rtcToken : rtcToken,
            callerUID: call.callerUID,
            calleeUID: call.calleeUID,
            channelID: call.channelID,
            channelType: call.channelType,
            callType: call.callType,
            requestedMediaMode: call.requestedMediaMode,
            mediaMode: call.mediaMode,
            peerCapabilityStatus: call.peerCapabilityStatus,
            callerCapabilities: call.callerCapabilities,
            callerDevice: call.callerDevice,
            calleeDevice: call.calleeDevice,
            acceptedDevice: call.acceptedDevice,
            callerProfile: call.callerProfile,
            calleeProfile: call.calleeProfile,
            callerName: call.callerName,
            calleeName: call.calleeName,
            callerAvatarURL: call.callerAvatarURL,
            callerAvatarVersion: call.callerAvatarVersion,
            callerAvatarUpdatedAt: call.callerAvatarUpdatedAt,
            calleeAvatarURL: call.calleeAvatarURL,
            calleeAvatarVersion: call.calleeAvatarVersion,
            calleeAvatarUpdatedAt: call.calleeAvatarUpdatedAt,
            createdAt: call.createdAt,
            updatedAt: call.updatedAt,
            startedAt: call.startedAt,
            acceptedAt: call.acceptedAt,
            endedAt: call.endedAt,
            endReason: call.endReason,
            stateVersion: call.stateVersion
        )
    }

    func voiceMediaPeerParticipant(call: RemoteRTCCall, joinedRoom: RemoteRTCRoomJoinData) -> RemoteRTCRoomParticipant? {
        rtcPeerParticipantResolution(call: call, joinedRoom: joinedRoom)?.participant
    }

    func joinedRoomPeerParticipant(call: RemoteRTCCall, joinedRoom: RemoteRTCRoomJoinData) -> RemoteRTCRoomParticipant? {
        rtcPeerParticipantResolution(call: call, joinedRoom: joinedRoom)?.participant
    }

    func rtcPeerParticipantResolution(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData
    ) -> RTCResolvedPeerParticipant? {
        RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: currentUserIdentitySet().union([
                joinedRoom.selfParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ].filter { !$0.isEmpty }),
            selfParticipant: joinedRoom.selfParticipant,
            explicitPeer: joinedRoom.peerParticipant,
            participants: joinedRoom.participants,
            directionHint: rtcPeerDirectionHint(callID: call.id)
        )
    }

    private func resolvedRTCPeerParticipant(
        explicitPeer: RemoteRTCRoomParticipant?,
        call: RemoteRTCCall,
        selfParticipant: RemoteRTCRoomParticipant?,
        participants: [RemoteRTCRoomParticipant]
    ) -> RemoteRTCRoomParticipant? {
        RTCDirectionAwarePeerResolver.resolve(
            call: call,
            selfUIDs: currentUserIdentitySet().union([
                selfParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ].filter { !$0.isEmpty }),
            selfParticipant: selfParticipant,
            explicitPeer: explicitPeer,
            participants: participants,
            directionHint: rtcPeerDirectionHint(callID: call.id)
        )?.participant
    }

    private func rtcPeerDirectionHint(callID: String) -> CallLifecycleDirection? {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              let activeVoiceCall,
              activeVoiceCall.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID else {
            return nil
        }
        switch activeVoiceCall.direction {
        case "呼出":
            return .outgoing
        case "来电":
            return .incoming
        default:
            return nil
        }
    }

#if DEBUG
    func waitForRTCPeerParticipantForTesting(
        call: RemoteRTCCall,
        joinedRoom: RemoteRTCRoomJoinData,
        policy: RTCPeerParticipantWaitPolicy
    ) async throws -> RemoteRTCRoomJoinData {
        try await joinedRoomReadyForVoiceStart(
            call: call,
            joinedRoom: joinedRoom,
            context: apiContext,
            roomID: call.roomID,
            rtcToken: call.rtcToken,
            scope: remoteDataScopeKey(for: apiContext),
            policy: policy
        )
    }
#endif

    func voiceDebug(routine: Bool = false, _ message: @autoclosure () -> String) {
        let value = message()
#if DEBUG
        if !routine || DebugConsoleDiagnostics.verbose {
            NSLog("[JHT RTC][AppState] %@", value)
        }
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(
                category: "AppState",
                media: rtcDiagnosticMediaLabel(for: value),
                message: value
            )
        }
    }

    // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: lifecycle-only diagnostics for lock/unlock RTC interface tracing.
    func logRTCLifecycleInterfaceEvent(_ event: String) {
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeCallID = activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let incomingCallID = incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heartbeatCallID = rtcMediaHeartbeatSession?.callID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heartbeatState = rtcMediaHeartbeatSession?.desiredMediaState ?? "none"
        let lastReportedState = rtcMediaHeartbeatSession?.lastReportedMediaState ?? "none"
        voiceDebug(
            "app_lifecycle interface=rtc event=\(normalizedEvent.isEmpty ? "unknown" : normalizedEvent) backgrounded=\(isApplicationBackgroundedForRTC) active=\(Self.shortDebugID(activeCallID)) incoming=\(Self.shortDebugID(incomingCallID)) heartbeat=\(Self.shortDebugID(heartbeatCallID)) desired=\(heartbeatState) last=\(lastReportedState) ending=\(isEndingActiveCall)"
        )
    }
    // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END

    private func rtcDiagnosticMediaLabel(for message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("video") || normalized.contains("media=video") || normalized.contains("media_mode=video") {
            return "video"
        }
        if normalized.contains("voice") || normalized.contains("media=audio") || normalized.contains("media_mode=audio") {
            return "voice"
        }
        if let call = activeVoiceCall {
            return call.isVideoCall || call.mediaMode == "video" || call.requestedMediaMode == "video" ? "video" : "voice"
        }
        if let incoming = incomingVoiceCall {
            return incoming.isVideo ? "video" : "voice"
        }
        return "unknown"
    }

    static func shortDebugID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return String(trimmed.suffix(6))
    }

    static func rtcDebugContextSummary(_ context: IMAPIContext) -> String {
        let appID = context.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "uid=\(shortDebugID(context.imUID ?? ""))",
            "app=\(appID.isEmpty ? "empty" : appID)",
            "device=\(shortDebugID(context.deviceID))",
            "tenant=\(shortDebugID(context.tenantID ?? ""))",
            "imSession=\(context.hasIMSession)"
        ].joined(separator: " ")
    }

    static func rtcStatusCountsSummary(_ statuses: [String]) -> String {
        let counts = statuses.reduce(into: [String: Int]()) { partial, rawStatus in
            let key = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            partial[key.isEmpty ? "empty" : key, default: 0] += 1
        }
        guard !counts.isEmpty else { return "none" }
        return counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
    }

    static func rtcIdentitySummary(_ identities: Set<String>) -> String {
        let items = identities.map { shortDebugID($0) }.sorted()
        return items.isEmpty ? "none" : items.joined(separator: "|")
    }

    static func voiceJoinSummary(callID: String, joinedRoom: RemoteRTCRoomJoinData) -> String {
        let selfDevice = joinedRoom.selfParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let peerDevice = joinedRoom.peerParticipant?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let selfID = joinedRoom.selfParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let peerID = joinedRoom.peerParticipant?.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let participantDeviceCount = joinedRoom.participants.filter {
            !$0.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return "join_ok call=\(shortDebugID(callID)) room=\(!joinedRoom.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) token=\(!joinedRoom.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) selfID=\(selfID) selfDevice=\(selfDevice) peerID=\(peerID) peerDevice=\(peerDevice) participants=\(joinedRoom.participants.count) participantDevices=\(participantDeviceCount) ice=\(joinedRoom.media.iceServers.count)"
    }

    static func safeVoiceErrorSummary(_ error: Error) -> String {
        if let apiError = error as? IMAPIError {
            switch apiError {
            case let .missingContext(message):
                return "missing_context:\(message)"
            case let .badURL(message):
                return "bad_url:\(message)"
            case let .unauthorized(message):
                return "unauthorized:\(message)"
            case let .forbidden(message):
                return "forbidden:\(message)"
            case let .businessForbidden(code, _, _):
                return "business_forbidden:\(code)"
            case let .conflict(code, _):
                return "conflict:\(code)"
            case let .server(message):
                return "server:\(message)"
            case let .httpStatus(statusCode, message):
                return "http_status:\(statusCode):\(message)"
            case .securityBlocked:
                return "security_blocked"
            case let .forcedAuthRequired(requirement):
                return "forced_auth_required:\(requirement.rawValue)"
            case let .loginSecurity(code, _, _):
                return "login_security:\(code)"
            case let .rateLimited(code, _, _, _):
                return "rate_limited:\(code)"
            case .emptyResponse:
                return "empty_response"
            }
        }
        if error is CancellationError {
            return "cancelled"
        }
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：保留安全的 NSError 定位字段，不记录 userInfo/token
        let nsError = error as NSError
        var parts = [
            "type=\(String(describing: type(of: error)))",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlyingDomain=\(underlying.domain)")
            parts.append("underlyingCode=\(underlying.code)")
        }
        return parts.joined(separator: " ")
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    }

    func stopVoiceMediaSession(reason: String) {
        voiceMediaEventTask?.cancel()
        voiceMediaEventTask = nil
        activeVoiceMediaCallID = nil
        pendingVoiceMediaJoinCallID = nil
        Task { [voiceMediaClient] in
            await voiceMediaClient.stop(reason: reason)
        }
    }

}

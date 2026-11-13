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
    struct RTCCallEventObservation {
        let payload: [String: JSONValue]
        let callPayload: [String: JSONValue]
        let event: String
        let status: String
        let callID: String
        let stateVersion: Int64

        init(_ envelope: RealtimeEnvelope) {
            payload = envelope.payload["rtc_call"]?.objectValue ?? envelope.payload
            callPayload = payload["call"]?.objectValue ?? [:]
            event = (payload["event"]?.stringValue ?? envelope.type).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            status = (payload["status"]?.stringValue ?? callPayload["status"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            callID = (payload["call_id"]?.stringValue ?? payload["id"]?.stringValue
                ?? callPayload["call_id"]?.stringValue ?? callPayload["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            stateVersion = Int64(payload["state_version"]?.stringValue ?? payload["stateVersion"]?.stringValue
                ?? callPayload["state_version"]?.stringValue ?? callPayload["stateVersion"]?.stringValue ?? "") ?? 0
        }

        var callerUID: String {
            (payload["caller_uid"]?.stringValue ?? payload["from_uid"]?.stringValue
                ?? callPayload["caller_uid"]?.stringValue ?? callPayload["from_uid"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var calleeUID: String {
            (payload["callee_uid"]?.stringValue ?? payload["target_uid"]?.stringValue
                ?? callPayload["callee_uid"]?.stringValue ?? callPayload["target_uid"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var isRinging: Bool { event == "rtc.call.ringing" || status == "ringing" }

        var terminalStatus: String? {
            let value: String
            if event.hasPrefix("rtc.call.") {
                value = String(event.dropFirst("rtc.call.".count))
            } else if event == "rtc_call" || event.isEmpty {
                value = status
            } else {
                return nil
            }
            switch value {
            case "canceled", "cancelled": return "canceled"
            case "timeout", "timed_out": return "timed_out"
            case "ended", "rejected", "busy": return value
            default: return nil
            }
        }
    }

    @discardableResult
    func handleRTCCallEvent(_ envelope: RealtimeEnvelope, scope: String? = nil) -> Bool {
        if let scope {
            guard isCurrentRemoteScope(scope) else { return false }
        }
        return handleRTCCallEvent(RTCCallEventObservation(envelope), scope: scope)
    }

    func handleRTCCallEvent(_ observation: RTCCallEventObservation, scope: String?) -> Bool {
        let payload = observation.payload
        let callPayload = observation.callPayload
        let event = observation.event
        let status = observation.status
        let callID = observation.callID
        let terminalStateVersion = observation.stateVersion
        let terminalReason = rtcTerminalReason(
            event: event,
            status: status,
            payload: payload,
            callPayload: callPayload
        )
        let historicalTiming = rtcHistoricalCallTiming(payload: payload, callPayload: callPayload)
        let callerUID = observation.callerUID
        let calleeUID = observation.calleeUID
        let roomID = (payload["room_id"]?.stringValue ?? callPayload["room_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = (payload["channel_id"]?.stringValue ?? callPayload["channel_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let identities = currentUserIdentitySet()
        let peerUID = identities.contains(callerUID) ? calleeUID : callerUID
        let peer = voiceCallPeer(
            from: payload,
            callPayload: callPayload,
            peerUID: peerUID,
            peerRole: identities.contains(callerUID) ? .callee : .caller,
            channelID: channelID
        )
        refreshVoiceCallPeerIfBetter(peer, matching: callID)

        if !callID.isEmpty,
           !terminalReason.isEmpty,
           activeVoiceCall?.callID != callID,
           incomingVoiceCall?.callID != callID,
           rtcTerminalMarkersByCallID[callID] != nil {
            refineTerminalMarkerAndRecord(
                callID: callID,
                reason: terminalReason,
                stateVersion: terminalStateVersion,
                historicalTiming: historicalTiming
            )
            return true
        }

        if observation.isRinging {
            guard !callerUID.isEmpty,
                  !identities.contains(callerUID),
                  calleeUID.isEmpty || identities.contains(calleeUID) else { return false }
            // A delayed ringing event for an already answered call is a replay,
            // not a competing incoming call. Pending same-ID calls are refined
            // by receiveIncomingVoiceCall's existing admission/ownership logic.
            if !callID.isEmpty, activeVoiceCall?.callID == callID {
                return true
            }
            if let reason = incomingVoiceCallUnavailableReason(for: peer) {
                if !callID.isEmpty {
                    rejectPresentedIncomingCallForAdmissionFailure(
                        callID: callID,
                        reason: "incoming_admission_unavailable"
                    )
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(reason)
                return true
            }
            if activeVoiceCall != nil
                || (incomingVoiceCall != nil && incomingVoiceCall?.callID != callID) {
                if !callID.isEmpty {
                    rejectCompetingIncomingCallIfPossible(callID: callID)
                }
                /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(activeVoiceCall != nil ? "当前正在通话中" : "请先处理当前来电")
                return true
            }
            receiveIncomingVoiceCall(
                from: peer,
                callID: callID,
                roomID: roomID,
                mediaMode: requestedRTCCallMediaMode(
                    payload: payload,
                    callPayload: callPayload
                ),
                stateVersion: terminalStateVersion,
                systemOwnsRingtone: voiceCallSystem.hasPresentedCall(callID: callID)
            )
            return true
        }

        if event == "rtc.call.busy" {
            let reasonCode = (payload["reason_code"]?.stringValue ?? payload["code"]?.stringValue ?? "callee_busy")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !callID.isEmpty,
                  activeVoiceCall?.callID == callID || incomingVoiceCall?.callID == callID else {
                voiceDebug("call_busy_ignore reason=foreign_or_empty call=\(Self.shortDebugID(callID))")
                return false
            }
            if advanceCallLifecycle(
                callID: callID,
                to: .busy,
                stateVersion: terminalStateVersion,
                reason: reasonCode
            ) {
                finishVoiceCallFromRemote(
                    status: "忙线",
                    subtitle: "语音通话 · 忙线",
                    toastText: rtcBusyMessage(reasonCode: reasonCode, fallback: payload["reason"]?.stringValue),
                    endReason: reasonCode,
                    stateVersion: terminalStateVersion,
                    expectedCallID: callID,
                    lifecyclePhase: .busy,
                    requiresAuthoritativeRevision: true,
                    lifecycleAlreadyApplied: true,
                    historicalTiming: historicalTiming
                )
            }
            return true
        }

        guard !callID.isEmpty,
              activeVoiceCall?.callID == callID || incomingVoiceCall?.callID == callID else { return false }
        switch event {
        case "rtc.call.accepted":
            if acceptedRTCCallIsBoundToCurrentCallee(
                payload: payload,
                callPayload: callPayload
            ) == false {
                // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: do not treat our in-flight answer as answered elsewhere.
                if shouldDeferAcceptedElsewhereWhileAnswering(callID: callID) {
                    voiceDebug("accepted_elsewhere_deferred issue=connect_drop call=\(Self.shortDebugID(callID)) reason=local_answer_in_progress")
                    return true
                }
                // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END
                finishVoiceCallFromRemote(
                    status: "已在其他设备接听",
                    subtitle: "语音通话 · 已在其他设备接听",
                    toastText: "已在其他设备接听",
                    endReason: "answered_elsewhere",
                    stateVersion: terminalStateVersion,
                    expectedCallID: callID,
                    lifecyclePhase: .ended
                )
                return true
            }
            if activeVoiceCall?.requiresAcceptedDeviceBeforeJoin != true { cancelVoiceCallWatchdog() }
            SystemNotificationSound.setOutgoingRingbackSuppressed(true)
            SystemNotificationSound.stopAllCallPrompts()
            handleVoiceMediaEvent(.callAccepted, callID: callID, scope: scope)
            startVoiceMediaSessionFromActiveCall(
                scope: scope ?? remoteDataScopeKey(for: apiContext),
                authoritativeCall: authoritativeRTCCall(
                    payload: payload,
                    callPayload: callPayload,
                    callID: callID,
                    status: status.isEmpty ? "accepted" : status
                )
            )
            /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast("\(peer.name) 已接听")
        case "rtc.call.rejected":
            finishVoiceCallFromRemote(
                status: "已拒绝",
                subtitle: "语音通话 · 对方已拒绝",
                toastText: "对方已拒绝语音通话",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .rejected,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        case "rtc.call.canceled":
            finishVoiceCallFromRemote(
                status: "已取消",
                subtitle: "语音通话 · 已取消",
                toastText: "语音通话已取消",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .cancelled,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        case "rtc.call.ended":
            finishVoiceCallFromRemote(
                status: "已结束",
                subtitle: "语音通话 · 通话已结束",
                toastText: "语音通话已结束",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .ended,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        case "rtc.call.timed_out":
            finishVoiceCallFromRemote(
                status: "未接通",
                subtitle: "语音通话 · 已超时",
                toastText: "语音通话已超时",
                endReason: terminalReason,
                stateVersion: terminalStateVersion,
                expectedCallID: callID,
                lifecyclePhase: .timeout,
                requiresAuthoritativeRevision: true,
                historicalTiming: historicalTiming
            )
        default:
            break
        }
        return [
            "rtc.call.accepted",
            "rtc.call.rejected",
            "rtc.call.canceled",
            "rtc.call.ended",
            "rtc.call.timed_out"
        ].contains(event)
    }

    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_BEGIN: local answering races can precede accepted-device reconciliation.
    func shouldDeferAcceptedElsewhereWhileAnswering(callID: String) -> Bool {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return false }
        if let active = activeVoiceCall,
           active.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID,
           active.direction == "来电",
           [.preparing, .signaling, .connecting].contains(active.mediaState) {
            return true
        }
        guard incomingCallAnswerMode != nil
                || callStore.incomingCallAnswerOperationID != nil else {
            return false
        }
        if incomingVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID {
            return true
        }
        return activeVoiceCall?.callID?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCallID
            && activeVoiceCall?.direction == "来电"
    }
    // WDT_RTC_ISSUE1_CONNECT_DROP_20260919_END

    private func acceptedRTCCallIsBoundToCurrentCallee(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> Bool? {
        let delivery = callPayload["delivery_context"]?.objectValue
            ?? callPayload["deliveryContext"]?.objectValue
            ?? payload["delivery_context"]?.objectValue
            ?? payload["deliveryContext"]?.objectValue
        guard let delivery else { return nil }
        let role = (delivery["viewer_role"]?.stringValue
            ?? delivery["viewerRole"]?.stringValue
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard role == "callee" else { return nil }
        return delivery["viewer_is_bound_participant"]?.boolValue
            ?? delivery["viewerIsBoundParticipant"]?.boolValue
    }

    func requestedRTCCallMediaMode(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> String {
        // State events carry the authoritative call either at the event root or
        // under `call`. Preserve the requested call type before considering an
        // accepted audio downgrade so a video call is never presented as voice.
        let requestedCandidates = [
            callPayload["call_type"]?.stringValue,
            callPayload["requested_media_mode"]?.stringValue,
            payload["call_type"]?.stringValue,
            payload["requested_media_mode"]?.stringValue
        ]
        let requestedModes = requestedCandidates.compactMap { candidate -> String? in
            switch candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "video": return "video"
            case "audio", "voice": return "audio"
            default: return nil
            }
        }
        if requestedModes.contains("video") { return "video" }
        if requestedModes.contains("audio") { return "audio" }

        let acceptedCandidates = [
            callPayload["media_mode"]?.stringValue,
            payload["media_mode"]?.stringValue,
            callPayload["accept_mode"]?.stringValue,
            payload["accept_mode"]?.stringValue
        ]
        for candidate in acceptedCandidates {
            switch candidate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "video": return "video"
            case "audio", "voice": return "audio"
            default: continue
            }
        }
        return "audio"
    }

    private func authoritativeRTCCall(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue],
        callID: String,
        status: String
    ) -> RemoteRTCCall? {
        var fields = callPayload
        let copiedKeys = [
            "id", "call_id", "room_id", "rtc_token", "caller_uid", "callee_uid", "target_uid",
            "channel_id", "channel_type", "call_type", "requested_media_mode", "media_mode",
            "peer_capability_status", "caller_device", "callee_device", "accepted_device",
            "caller_device_id", "callee_device_id", "accepted_device_id", "state_version"
        ]
        for key in copiedKeys where fields[key] == nil {
            fields[key] = payload[key]
        }
        if fields["id"] == nil, fields["call_id"] == nil, !callID.isEmpty {
            fields["id"] = .string(callID)
        }
        if fields["status"] == nil {
            fields["status"] = .string(status)
        }

        let callerUID = fields["caller_uid"]?.stringValue ?? ""
        let calleeUID = fields["callee_uid"]?.stringValue
            ?? fields["target_uid"]?.stringValue
            ?? ""
        func normalizedDevice(
            objectKey: String,
            idKeys: [String],
            uid: String
        ) -> JSONValue? {
            if let existing = fields[objectKey]?.objectValue {
                return .object(existing)
            }
            let deviceID = idKeys.lazy.compactMap { key in
                fields[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first(where: { !$0.isEmpty }) ?? ""
            guard !deviceID.isEmpty else { return nil }
            return .object([
                "uid": .string(uid),
                "device_id": .string(deviceID),
                "device_type": .string("")
            ])
        }
        if fields["caller_device"] == nil {
            fields["caller_device"] = normalizedDevice(
                objectKey: "caller_device",
                idKeys: ["caller_device_id"],
                uid: callerUID
            )
        }
        if fields["callee_device"] == nil {
            fields["callee_device"] = normalizedDevice(
                objectKey: "callee_device",
                idKeys: ["callee_device_id", "accepted_device_id"],
                uid: calleeUID
            )
        }
        if fields["accepted_device"] == nil {
            fields["accepted_device"] = normalizedDevice(
                objectKey: "accepted_device",
                idKeys: ["accepted_device_id", "callee_device_id"],
                uid: calleeUID
            )
        }
        guard let data = try? JSONEncoder().encode(fields),
              let call = try? JSONDecoder().decode(RemoteRTCCall.self, from: data),
              call.id.trimmingCharacters(in: .whitespacesAndNewlines) == callID else {
            return nil
        }
        return call
    }

    func rtcTerminalReason(
        event: String,
        status: String,
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> String {
        let explicit = (
            payload["end_reason"]?.stringValue
                ?? payload["endReason"]?.stringValue
                ?? payload["reason_code"]?.stringValue
                ?? payload["reason"]?.stringValue
                ?? callPayload["end_reason"]?.stringValue
                ?? callPayload["endReason"]?.stringValue
                ?? callPayload["reason_code"]?.stringValue
                ?? callPayload["reason"]?.stringValue
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        switch event {
        case "rtc.call.rejected": return "rejected"
        case "rtc.call.canceled": return "canceled"
        case "rtc.call.ended": return "remote_hangup"
        case "rtc.call.timed_out": return "timeout"
        default:
            switch status {
            case "rejected": return "rejected"
            case "canceled": return "canceled"
            case "ended": return "remote_hangup"
            case "timed_out": return "timeout"
            default: return ""
            }
        }
    }

    private func rtcBusyMessage(reasonCode: String, fallback: String? = nil) -> String {
        switch reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "duplicate_call":
            return "已有进行中的语音呼叫，请勿重复发起"
        case "caller_busy":
            return "你正在通话中，请结束后再试"
        case "callee_busy":
            return "对方正在通话中"
        default:
            let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "语音通话忙线，请稍后再试" : trimmed
        }
    }

}

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
    func isCurrentRTCCallPoll(_ scope: LocalMessageScope, generation: UInt64) -> Bool {
        generation == localMessageSessionGeneration && callRecordRuntimeScope(for: apiContext) == scope
    }

    func hasCurrentCallRecordBinding() -> Bool {
        guard let scope = callRecordRuntimeScope(for: apiContext) else { return false }
        return callStore.hasCallRecordPersistenceBinding(for: scope)
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
    @discardableResult
    func refreshRTCCallEventsSilently() async -> RTCRefreshResult {
        let context = apiContext
        let scope = remoteDataScopeKey(for: context)
        return await refreshRTCCallEventsSilently(context: context, scope: scope)
    }

    // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
    @discardableResult
    func refreshRTCCallEventsSilently(
        context: IMAPIContext,
        scope: String,
        allowBackgroundExecution: Bool = false
    ) async -> RTCRefreshResult {
        guard !JHTRuntimeFeatureFlags.disableRTCRuntime else { return .skipped }
        guard !Task.isCancelled else { return .cancelled }
        guard let runtimeScope = callRecordRuntimeScope(for: context),
              runtimeScope == callRecordRuntimeScope(for: apiContext),
              isCurrentRemoteScope(scope) else {
            voiceDebug("events_refresh_skip context=\(Self.rtcDebugContextSummary(context)) scope_current=\(isCurrentRemoteScope(scope))")
            return .skipped
        }
        guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
            voiceDebug("events_refresh_skip gate=background context=\(Self.rtcDebugContextSummary(context))")
            return .skipped
        }
        // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
        if let inFlightScope = rtcEventsRefreshInFlightScope,
           inFlightScope == scope {
            voiceDebug("events_refresh_skip gate=in_flight context=\(Self.rtcDebugContextSummary(context))")
            return .skipped
        }
        let sessionGeneration = localMessageSessionGeneration
        rtcEventsRefreshInFlightScope = scope
        defer {
            if rtcEventsRefreshInFlightScope == scope {
                rtcEventsRefreshInFlightScope = nil
            }
            schedulePendingRTCSignalingRefresh()
        }
        do {
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_BEGIN: log RTC request attempts around lock/unlock without changing request payload.
            voiceDebug(
                routine: true, "request_interface path=/api/rtc/calls/events backgrounded=\(isApplicationBackgroundedForRTC) allow_background=\(allowBackgroundExecution) context=\(Self.rtcDebugContextSummary(context))"
            )
            // WDT_RTC_LOCKSCREEN_INTERFACE_LOGS_20260924_END
            let events = try await api.listRTCCallEvents(context: context)
            guard !Task.isCancelled,
                  isCurrentRemoteScope(scope),
                  isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration),
                  allowBackgroundExecution || !isApplicationBackgroundedForRTC else {
                voiceDebug("events_refresh_discard scope_changed count=\(events.count)")
                return .cancelled
            }
            voiceDebug(routine: true, "events_refresh_ok http=2xx count=\(events.count) types=\(Self.rtcStatusCountsSummary(events.map(\.type))) context=\(Self.rtcDebugContextSummary(context))")
            let observations = events.map { event in
                RTCCallEventObservation(RealtimeEnvelope(type: event.type, requestID: nil, payload: event.payload))
            }
            let closedBeforePresentation = reconcileUnownedPolledTerminals(observations)
            var processedNotificationIDs: [String] = []
            for (event, observation) in zip(events, observations) {
                // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
                guard !Task.isCancelled,
                      isCurrentRemoteScope(scope),
                      isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration),
                      allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
                // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
                let isClosedReplay = closedBeforePresentation.contains(observation.callID)
                    && (observation.terminalStatus != nil || observation.isRinging || observation.event == "rtc.call.accepted")
                if isClosedReplay || handleRTCCallEvent(observation, scope: scope),
                   !event.notificationID.isEmpty {
                    processedNotificationIDs.append(event.notificationID)
                }
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            if !processedNotificationIDs.isEmpty,
               !Task.isCancelled,
               isCurrentRemoteScope(scope),
               isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration),
               allowBackgroundExecution || !isApplicationBackgroundedForRTC {
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
                try? await api.ackRTCCallEventNotifications(
                    context: context,
                    notificationIDs: processedNotificationIDs
                )
            }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            return .success
        } catch {
            guard isCurrentRemoteScope(scope),
                  isCurrentRTCCallPoll(runtimeScope, generation: sessionGeneration) else { return .cancelled }
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_LIFECYCLE_20260911
            guard allowBackgroundExecution || !isApplicationBackgroundedForRTC else { return .cancelled }
            // JHT_MOD_END IOS_RTC_REQUEST_LIFECYCLE_20260911
            voiceDebug("events_refresh_failed error=\(Self.safeVoiceErrorSummary(error))")
            logSyncEndpointFailure("/api/rtc/calls/events", error: error)
            return .failed(error)
        }
    }
    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910

    private func reconcileUnownedPolledTerminals(_ observations: [RTCCallEventObservation]) -> Set<String> {
        let owned = Set([
            activeVoiceCall?.callID,
            incomingVoiceCall?.callID,
            callStore.activeLifecycleSnapshot?.identity.callID
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
        var terminalIndexByID: [String: Int] = [:]
        var newestNonterminalRevision: [String: Int64] = [:]
        var incomingByID: [String: RTCCallEventObservation] = [:]
        let identities = currentUserIdentitySet()
        for (index, observation) in observations.enumerated()
            where !observation.callID.isEmpty && !owned.contains(observation.callID) {
            let callID = observation.callID
            if observation.terminalStatus != nil {
                if terminalIndexByID[callID].map({ observations[$0].stateVersion <= observation.stateVersion }) ?? true {
                    terminalIndexByID[callID] = index
                }
            } else {
                newestNonterminalRevision[callID] = max(newestNonterminalRevision[callID] ?? 0, observation.stateVersion)
                if observation.isRinging, !observation.callerUID.isEmpty, !identities.contains(observation.callerUID),
                   observation.calleeUID.isEmpty || identities.contains(observation.calleeUID) {
                    incomingByID[callID] = observation
                }
            }
        }

        var closed: Set<String> = []
        for index in terminalIndexByID.values.sorted() {
            let terminal = observations[index]
            let callID = terminal.callID
            // A terminal revision older than a known live revision cannot close it.
            guard terminal.stateVersion <= 0 || terminal.stateVersion >= (newestNonterminalRevision[callID] ?? 0),
                  let status = terminal.terminalStatus else { continue }
            closed.insert(callID)
            let explicitReason = rtcTerminalReason(
                event: "rtc.call.\(status)", status: status, payload: terminal.payload, callPayload: terminal.callPayload
            )
            let reason = explicitReason.isEmpty ? status : explicitReason
            let timing = rtcHistoricalCallTiming(payload: terminal.payload, callPayload: terminal.callPayload)
            if rtcTerminalMarkersByCallID[callID] != nil {
                refineTerminalMarkerAndRecord(
                    callID: callID, reason: reason, stateVersion: terminal.stateVersion, historicalTiming: timing
                )
                continue
            }
            // The inbox can contain ringing followed by cancellation from
            // before launch. Acknowledge both without claiming a local call.
            rtcTerminalMarkersByCallID[callID] = RTCCallTerminalMarker(
                callID: callID, reason: reason, stateVersion: max(0, terminal.stateVersion)
            )
            if let ringing = incomingByID[callID] {
                ensureCallRecordPersistenceBindingIfNeeded()
                guard !calls.contains(where: { $0.callID == callID }) else { continue }
                let channelID = ringing.payload["channel_id"]?.stringValue ?? ringing.callPayload["channel_id"]?.stringValue ?? ""
                let peer = voiceCallPeer(
                    from: ringing.payload, callPayload: ringing.callPayload, peerUID: ringing.callerUID,
                    peerRole: .caller, channelID: channelID
                )
                let media = requestedRTCCallMediaMode(payload: ringing.payload, callPayload: ringing.callPayload) == "video"
                    ? "视频" : "语音"
                let summary: String
                switch status {
                case "canceled": summary = "已取消"
                case "rejected": summary = "已拒绝"
                case "timed_out": summary = "未接通"
                case "busy": summary = "忙线"
                default: summary = "已结束"
                }
                upsertVoiceCallRecord(
                    callID: callID, title: peer.name, subtitle: "\(media)来电 · \(summary)",
                    status: summary, direction: .incoming, peer: peer,
                    startedAt: timing.startedAt, endedAt: timing.endedAt, durationSeconds: timing.durationSeconds,
                    endReason: reason, stateVersion: terminal.stateVersion, replaceHistoricalTiming: true
                )
            }
            voiceDebug("events_replay_closed call=\(Self.shortDebugID(callID)) status=\(status)")
        }
        return closed
    }

    struct RTCHistoricalCallTiming {
        var startedAt: Date?
        var endedAt: Date?
        var durationSeconds: TimeInterval?

        static let unknown = RTCHistoricalCallTiming()
    }

    func rtcHistoricalCallTiming(_ call: RemoteRTCCall) -> RTCHistoricalCallTiming {
        rtcHistoricalCallTiming(payload: [
            "started_at": .string(call.startedAt),
            "accepted_at": .string(call.acceptedAt),
            "ended_at": .string(call.endedAt)
        ], callPayload: [:])
    }

    func rtcHistoricalCallTiming(
        payload: [String: JSONValue],
        callPayload: [String: JSONValue]
    ) -> RTCHistoricalCallTiming {
        // Only server event times enter history. Neither delivery time nor the
        // local media clock is a substitute for missing server fields.
        func field(_ key: String) -> JSONValue? { callPayload[key] ?? payload[key] }
        func date(_ value: JSONValue?) -> (Date?, Bool) {
            guard let value else { return (nil, true) }
            if case .null = value { return (nil, true) }
            guard case .string(let raw) = value else { return (nil, false) }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, true) }
            let parsed = RTCCallRecordTimeProjection.parseServerTimestamp(raw)
            return (parsed, parsed != nil)
        }
        let (started, validStart) = date(field("started_at"))
        let (answered, validAnswer) = date(field("answered_at") ?? field("accepted_at"))
        let (connected, validMedia) = date(field("media_connected_at"))
        let (ended, validEnd) = date(field("ended_at"))
        guard validStart, validAnswer, validMedia, validEnd else { return .unknown }
        let timeline = [started, answered, connected, ended].compactMap { $0 }
        guard zip(timeline, timeline.dropFirst()).allSatisfy({ $0 <= $1 }) else { return .unknown }

        var duration: TimeInterval?
        if let supplied = field("duration_seconds"), supplied != .null {
            let seconds: Int?
            switch supplied {
            case .int(let value): seconds = value
            case .double(let value): seconds = value.isFinite ? Int(exactly: value) : nil
            case .string(let value): seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            default: seconds = nil
            }
            // WDT_IOS1_CALL_DURATION_20261023_BEGIN
            guard let seconds, let exactSeconds = RTCCallRecordTimeProjection.exactDurationSeconds(seconds) else { return .unknown }
            // Positive duration requires media connection; signaling answer or
            // ringing alone must never manufacture a connected duration.
            if ended != nil, seconds == 0 || connected != nil {
                duration = exactSeconds
            }
        } else if let connected, let ended {
            duration = RTCCallRecordTimeProjection.validatedDurationSeconds(floor(ended.timeIntervalSince(connected)))
        }
        // WDT_IOS1_CALL_DURATION_20261023_END
        return RTCHistoricalCallTiming(startedAt: started, endedAt: ended, durationSeconds: duration)
    }

    func finishVoiceCallFromRemote(
        status: String,
        subtitle: String,
        toastText: String,
        endReason: String = "",
        stateVersion: Int64 = 0,
        mediaAlreadyStopped: Bool = false,
        expectedCallID: String? = nil,
        lifecyclePhase: CallLifecyclePhase = .ended,
        requiresAuthoritativeRevision: Bool = false,
        lifecycleAlreadyApplied: Bool = false,
        historicalTiming: RTCHistoricalCallTiming = .unknown
    ) {
        let currentCallID = (activeVoiceCall?.callID ?? incomingVoiceCall?.callID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpectedCallID = expectedCallID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? currentCallID
        guard !normalizedExpectedCallID.isEmpty,
              currentCallID == normalizedExpectedCallID else {
            voiceDebug("call_finish_ignore reason=identity_mismatch expected=\(Self.shortDebugID(normalizedExpectedCallID)) current=\(Self.shortDebugID(currentCallID))")
            return
        }
        if !lifecycleAlreadyApplied, callStore.activeLifecycleSnapshot != nil {
            let accepted = advanceCallLifecycle(
                callID: normalizedExpectedCallID,
                to: lifecyclePhase,
                stateVersion: requiresAuthoritativeRevision ? stateVersion : nil,
                reason: endReason.isEmpty ? lifecyclePhase.rawValue : endReason
            )
            guard accepted else {
                voiceDebug("call_finish_ignore reason=lifecycle_rejected call=\(Self.shortDebugID(normalizedExpectedCallID)) phase=\(lifecyclePhase.rawValue) version=\(stateVersion)")
                return
            }
        }
        cancelVoiceCallWatchdog()
        SystemNotificationSound.setSystemOwnsIncomingRingtone(false)
        SystemNotificationSound.stopIncomingCallFallback()
        let peer = activeVoiceCall?.peer ?? incomingVoiceCall?.caller
        let activeCall = activeVoiceCall
        let isVideoCall = activeCall?.isVideoCall == true || incomingVoiceCall?.isVideo == true
        let normalizedSubtitle = isVideoCall
            ? subtitle.replacingOccurrences(of: "语音通话", with: "视频通话")
            : subtitle
        let normalizedToastText = isVideoCall
            ? toastText.replacingOccurrences(of: "语音通话", with: "视频通话")
            : toastText
        let systemCallID = activeVoiceCall?.callID ?? incomingVoiceCall?.callID
        let normalizedCallID = systemCallID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedEndReason = endReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCallID.isEmpty, !normalizedEndReason.isEmpty {
            rtcTerminalMarkersByCallID[normalizedCallID] = RTCCallTerminalMarker(
                callID: normalizedCallID,
                reason: normalizedEndReason,
                stateVersion: max(0, stateVersion)
            )
        }
        if let peer {
            let direction = currentVoiceCallRecordDirection()
            upsertVoiceCallRecord(
                callID: systemCallID,
                title: peer.name,
                subtitle: normalizedVoiceCallRecordSubtitle(normalizedSubtitle, direction: direction),
                status: status,
                direction: direction,
                peer: peer,
                startedAt: historicalTiming.startedAt,
                endedAt: historicalTiming.endedAt,
                durationSeconds: historicalTiming.durationSeconds,
                endReason: normalizedEndReason,
                stateVersion: stateVersion,
                replaceHistoricalTiming: true
            )
        }
        if let callID = systemCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callID.isEmpty {
            voiceCallSystem.endCall(callID: callID, reason: status)
            voipPushPayloadsByCallID.removeValue(forKey: callID)
        }
        if mediaAlreadyStopped, !normalizedCallID.isEmpty {
            stoppedVideoMediaCallIDs.insert(normalizedCallID)
            videoMediaEventTask?.cancel()
            videoMediaEventTask = nil
            activeVideoMediaCallID = nil
        } else {
            stopCallMediaSession(for: activeCall, reason: "remote_ended")
        }
        if let callID = systemCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !callID.isEmpty {
            rtcPeerWaitTerminationCallIDs.remove(callID)
            releaseDirectCallTracking(callID: callID)
        }
        activeVoiceCall = nil
        incomingVoiceCall = nil
        // An unanswered incoming banner can end while the user is elsewhere.
        // Keep its record and toast, but don't open a new full-screen result.
        if activeCall?.isVideoCall == true, let peer {
            presentVideoCallTerminal(
                callID: normalizedCallID,
                peer: peer,
                reason: normalizedEndReason.isEmpty ? normalizedToastText : normalizedEndReason,
                fallback: status,
                connectedAt: activeCall?.connectedAt,
                endedAt: Date() // Transient terminal presentation only; never persisted above.
            )
        }
        releaseAudioSessionForVoiceCall()
        // JHT_MOD_BEGIN RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改开始：远端/轮询终态后静默补拉对应私聊消息
        if !isVideoCall {
            syncRTCCallRecordConversationAfterTerminalIfPossible(
                channelID: nil,
                peer: peer,
                peerUID: nil,
                phase: lifecyclePhase,
                reason: normalizedEndReason.isEmpty ? lifecyclePhase.rawValue : normalizedEndReason
            )
        }
        // JHT_MOD_END RTC_CALL_RECORD_CHAT_SYNC_20260914 - 修改结束
        /* WDT_IOS1_REFACTOR_TOAST_COMMAND_BOUNDARY_20261110 */ setToast(normalizedToastText)
    }

    func upsertVoiceCallRecord(
        callID: String?,
        title: String,
        subtitle: String,
        status: String,
        direction: CallRecordDirection,
        peer: IMUser? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        endReason: String = "",
        stateVersion: Int64 = 0,
        replaceHistoricalTiming: Bool = false
    ) {
        ensureCallRecordPersistenceBindingIfNeeded()
        guard hasCurrentCallRecordBinding() else { return }
        let normalizedCallID = callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingIndex: Int?
        if !normalizedCallID.isEmpty {
            existingIndex = calls.firstIndex { $0.callID == normalizedCallID }
        } else {
            existingIndex = calls.firstIndex {
                $0.title == title
                    && $0.direction == direction
                    && ["呼叫中", "来电中", "通话中"].contains($0.status)
            }
        }
        let existing = existingIndex.map { calls[$0] }
        let existingID = existingIndex.map { calls[$0].id } ?? "call_record_\(UUID().uuidString)"
        let normalizedPeerID = peer?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerUserID = peer?.userID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarURL = peer?.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarVersion = peer?.avatarVersion.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarUpdatedAt = peer?.avatarUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPeerAvatarSource = voiceCallAvatarSource(for: peer)
        let resolvedStartedAt = replaceHistoricalTiming ? startedAt : (startedAt ?? existing?.startedAt)
        let resolvedEndedAt = replaceHistoricalTiming ? endedAt : (endedAt ?? existing?.endedAt)
        // WDT_IOS1_CALL_DURATION_20261023_BEGIN
        let resolvedDurationSeconds = RTCCallRecordTimeProjection.validatedDurationSeconds(
            replaceHistoricalTiming ? durationSeconds : (durationSeconds ?? existing?.durationSeconds)
        )
        // WDT_IOS1_CALL_DURATION_20261023_END
        let normalizedEndReason = endReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEndReason = normalizedEndReason.isEmpty ? (existing?.endReason ?? "") : normalizedEndReason
        let resolvedStateVersion = max(existing?.stateVersion ?? 0, stateVersion)
        let next = CallRecord(
            id: existingID,
            callID: normalizedCallID.isEmpty ? nil : normalizedCallID,
            peerID: normalizedPeerID.isEmpty ? (existing?.peerID ?? "") : normalizedPeerID,
            peerUserID: normalizedPeerUserID.isEmpty ? (existing?.peerUserID ?? "") : normalizedPeerUserID,
            peerAvatarURL: normalizedPeerAvatarURL.isEmpty ? (existing?.peerAvatarURL ?? "") : normalizedPeerAvatarURL,
            peerAvatarVersion: normalizedPeerAvatarVersion.isEmpty ? (existing?.peerAvatarVersion ?? "") : normalizedPeerAvatarVersion,
            peerAvatarUpdatedAt: normalizedPeerAvatarUpdatedAt.isEmpty ? (existing?.peerAvatarUpdatedAt ?? "") : normalizedPeerAvatarUpdatedAt,
            peerAvatarSource: normalizedPeerAvatarSource.isEmpty ? (existing?.peerAvatarSource ?? "") : normalizedPeerAvatarSource,
            title: title,
            subtitle: subtitle,
            time: voiceCallRecordDisplayTime(startedAt: resolvedStartedAt, endedAt: resolvedEndedAt, existingTime: replaceHistoricalTiming ? "时间未知" : existing?.time),
            status: status,
            direction: direction,
            callType: voiceCallRecordType(subtitle: subtitle, existing: existing),
            startedAt: resolvedStartedAt,
            endedAt: resolvedEndedAt,
            durationSeconds: resolvedDurationSeconds,
            endReason: resolvedEndReason,
            stateVersion: resolvedStateVersion
        )
        if let existingIndex {
            calls.remove(at: existingIndex)
        }
        calls.insert(next, at: 0)
        let seen = Set(calls.compactMap(\.callID))
        guard !seen.isEmpty else { return }
        var retained: [CallRecord] = []
        var retainedCallIDs: Set<String> = []
        for record in calls {
            if let callID = record.callID, !callID.isEmpty {
                guard !retainedCallIDs.contains(callID) else { continue }
                retainedCallIDs.insert(callID)
            }
            retained.append(record)
        }
        calls = Array(retained.prefix(20))
    }

    private func voiceCallRecordType(subtitle: String, existing: CallRecord?) -> String {
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSubtitle.hasPrefix("视频") {
            return "视频通话"
        }
        if trimmedSubtitle.hasPrefix("语音") {
            return "语音通话"
        }
        let existingType = existing?.callType.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return existingType.isEmpty ? "语音通话" : existingType
    }

    func refineTerminalMarkerAndRecord(
        callID: String,
        reason: String,
        stateVersion: Int64,
        historicalTiming: RTCHistoricalCallTiming = .unknown
    ) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasCurrentCallRecordBinding(),
              !normalizedCallID.isEmpty,
              !normalizedReason.isEmpty,
              var marker = rtcTerminalMarkersByCallID[normalizedCallID] else {
            return
        }
        let normalizedVersion = max(0, stateVersion)
        if marker.stateVersion > 0, normalizedVersion == 0 { return }
        if normalizedVersion > 0, normalizedVersion < marker.stateVersion { return }
        guard let index = calls.firstIndex(where: { $0.callID == normalizedCallID }) else { return }
        let existing = calls[index]
        let canRefineTiming = existing.endedAt == nil && historicalTiming.endedAt != nil
        guard marker.reason == "server_signal_terminal" || canRefineTiming else { return }
        if marker.reason == "server_signal_terminal" { marker.reason = normalizedReason }
        marker.stateVersion = max(marker.stateVersion, normalizedVersion)
        rtcTerminalMarkersByCallID[normalizedCallID] = marker
        calls[index] = CallRecord(
            id: existing.id,
            callID: existing.callID,
            peerID: existing.peerID,
            peerUserID: existing.peerUserID,
            peerAvatarURL: existing.peerAvatarURL,
            peerAvatarVersion: existing.peerAvatarVersion,
            peerAvatarUpdatedAt: existing.peerAvatarUpdatedAt,
            peerAvatarSource: existing.peerAvatarSource,
            title: existing.title,
            subtitle: existing.subtitle,
            time: canRefineTiming
                ? voiceCallRecordDisplayTime(startedAt: historicalTiming.startedAt, endedAt: historicalTiming.endedAt, existingTime: "时间未知")
                : existing.time,
            status: existing.status,
            direction: existing.direction,
            callType: existing.callType,
            startedAt: canRefineTiming ? historicalTiming.startedAt : existing.startedAt,
            endedAt: canRefineTiming ? historicalTiming.endedAt : existing.endedAt,
            // WDT_IOS1_CALL_DURATION_20261023_BEGIN
            durationSeconds: RTCCallRecordTimeProjection.validatedDurationSeconds(
                canRefineTiming ? historicalTiming.durationSeconds : existing.durationSeconds
            ),
            // WDT_IOS1_CALL_DURATION_20261023_END
            endReason: marker.reason,
            stateVersion: marker.stateVersion
        )
    }

    private func voiceCallRecordDisplayTime(startedAt: Date?, endedAt: Date?, existingTime: String?) -> String {
        if let endedAt {
            return displayTime(endedAt)
        }
        if let startedAt {
            return displayTime(startedAt)
        }
        let fallback = existingTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "刚刚" : fallback
    }

    func voiceCallDurationSeconds(for call: VoiceCallSession, endedAt: Date, finalStatus: String) -> TimeInterval {
        guard finalStatus.contains("结束") || call.statusText == "通话中" else { return 0 }
        guard let connectedAt = call.connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }

    private func currentVoiceCallRecordDirection() -> CallRecordDirection {
        if activeVoiceCall?.direction == "来电" || incomingVoiceCall != nil {
            return .incoming
        }
        return .outgoing
    }

    private func normalizedVoiceCallRecordSubtitle(_ subtitle: String, direction: CallRecordDirection) -> String {
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard direction == .incoming || direction == .outgoing else { return trimmed }
        if trimmed.hasPrefix("语音来电")
            || trimmed.hasPrefix("语音呼出")
            || trimmed.hasPrefix("视频来电")
            || trimmed.hasPrefix("视频呼出") {
            return trimmed
        }
        let callKind = trimmed.hasPrefix("视频") ? "视频" : "语音"
        let prefix = direction == .incoming ? "\(callKind)来电" : "\(callKind)呼出"
        if let suffix = trimmed.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suffix.isEmpty,
           suffix != trimmed {
            return "\(prefix) · \(suffix)"
        }
        return trimmed.isEmpty ? prefix : "\(prefix) · \(trimmed)"
    }

}

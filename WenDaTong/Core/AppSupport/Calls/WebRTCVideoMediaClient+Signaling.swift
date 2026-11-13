import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
@MainActor
extension WebRTCVideoMediaClient {
    func startSignalPolling(context: VideoMediaSessionContext) {
        signalPollTask?.cancel()
        signalState.invalidatePolling()
        let generation = signalState.generation
        let pollSessionEpoch = sessionEpoch
        let pollCallID = context.callID
        signalPollTask = Task { @MainActor [weak self] in
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            var pollingBackoff = RTCSignalPollingBackoffState()
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
            while !Task.isCancelled {
                guard let self,
                      self.isCurrentSignalSession(
                        generation: generation,
                        sessionEpoch: pollSessionEpoch,
                        callID: pollCallID
                      ) else { break }
                do {
                    let cursor = self.signalState.cursor
                    let token = self.signalState.rtcToken
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    let pollStartedAt = DispatchTime.now().uptimeNanoseconds
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                    let page = try await context.pollSignals(cursor, token)
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    let pollElapsed = DispatchTime.now().uptimeNanoseconds - pollStartedAt
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                    try Task.checkCancellation()
                    guard self.isCurrentSignalSession(
                        generation: generation,
                        sessionEpoch: pollSessionEpoch,
                        callID: pollCallID
                    ) else { break }
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    pollingBackoff.reset()
                    let next = page.nextCursor.trimmingCharacters(in: .whitespacesAndNewlines)
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                    if !page.items.isEmpty {
                        self.videoDebug(
                            "signal_poll_ok items=\(page.items.count) kinds=\(page.items.map { $0.kind.rawValue }.joined(separator: ",")) cursorAdvanced=\(!page.nextCursor.isEmpty && page.nextCursor != cursor)"
                        )
                    }
                    for item in page.items {
                        try Task.checkCancellation()
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        if self.signalState.hasProcessed(item.messageID) {
                            continue
                        }
                        try await self.handleSignal(item)
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        self.signalState.markProcessed(item.messageID)
                    }
                    self.inBandCredentialRefresh.requireAcknowledgement(of: next)
                    var didAcknowledgeAndCommit = false
                    if !next.isEmpty, next != self.signalState.cursor {
                        try await context.acknowledgeSignals(next, self.signalState.rtcToken)
                        try Task.checkCancellation()
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        self.signalState.commitCursor(next)
                        didAcknowledgeAndCommit = true
                    }
                    try? await self.flushSignalOutbox()
                    _ = self.inBandCredentialRefresh.completeAfterAcknowledgement(
                        acknowledgedCursor: self.signalState.cursor,
                        didAcknowledgeAndCommit: didAcknowledgeAndCommit
                    )
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260910
                    if let emptyDelay = RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                        itemCount: page.items.count,
                        previousCursor: cursor,
                        nextCursor: next,
                        elapsedNanoseconds: pollElapsed,
                        isConnected: self.connectedEmitted && self.iceConnected
                    ) {
                        self.videoDebug("signal_poll_quick_empty_delay elapsed_ms=\(pollElapsed / 1_000_000) delay_ms=\(emptyDelay / 1_000_000) connected=\(self.connectedEmitted && self.iceConnected)")
                        try? await Task.sleep(nanoseconds: emptyDelay)
                    }
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260910
                } catch is CancellationError {
                    break
                } catch {
                    self.videoDebug(
                        "signal_poll_failed error=\(Self.safeErrorLabel(error)) iceConnected=\(self.iceConnected)"
                    )
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    if RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(error) {
                        self.videoDebug("signal_poll_terminal error=\(Self.safeErrorLabel(error))")
                        self.emit(.serverSignalTerminal)
                        await self.closeCurrent(
                            reason: "server_signal_terminal",
                            sendBye: false,
                            finishStream: true,
                            releasePreview: true
                        )
                        break
                    }
                    if RTCSignalPollingBackoffPolicy.shouldStopPolling(after: error) {
                        self.videoDebug("signal_poll_stop error=\(Self.safeErrorLabel(error))")
                        break
                    }
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    if RTCVideoSignalPollingFailurePolicy.shouldEmitReconnecting(
                        after: error,
                        iceConnected: self.iceConnected
                    ) {
                        self.emit(.reconnecting)
                    }
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    let delay = pollingBackoff.recordFailureAndDelayNanoseconds(stableKey: pollCallID, error: error)
                    self.videoDebug("signal_poll_backoff delay_ms=\(delay / 1_000_000)")
                    try? await Task.sleep(nanoseconds: delay)
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                }
            }
        }
    }

    private func isCurrentSignalSession(
        generation: Int,
        sessionEpoch: Int,
        callID: String
    ) -> Bool {
        self.sessionEpoch == sessionEpoch
            && currentContext?.callID == callID
            && signalState.isCurrent(generation: generation)
    }

    private func handleSignal(_ item: RemoteRTCSignalItem) async throws {
        guard let context = currentContext else { return }
        guard acceptsRemoteSignal(item, context: context) else { return }
        videoDebug(
            "signal_handle kind=\(item.kind.rawValue) fromDeviceHash=\(Self.shortStableHash(item.fromDevice)) targetDeviceHash=\(Self.shortStableHash(item.toDevice))"
        )
        switch item.kind {
        case .offer, .answer:
            try await handleDescription(item)
        case .candidate:
            guard acceptsNegotiation(item.negotiationID) else { return }
            try await handleCandidates(item.data)
        case .iceRestart:
            if context.isCaller {
                try await refreshCredentialsAndRestartAsCaller(
                    inBandSignalRefresh: true
                )
            }
        case .mediaState:
            let mediaMode = item.data["media_mode"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if mediaMode == "audio" {
                activeMediaMode = "audio"
                cameraEnabledIntent = false
                localVideoTrack?.isEnabled = false
                await stopCaptureIfNeeded()
                emit(.remoteDowngradedToAudio)
                maybeEmitConnected()
                return
            }
            if let enabled = item.data["camera_enabled"]?.boolValue {
                if enabled {
                    remoteCameraPausedByContract = false
                    remoteVideoFrameReady = false
                    rearmRemoteFirstFrameObserver()
                } else {
                    remoteCameraPausedByContract = true
                }
                emit(enabled ? .remoteCameraResumed : .remoteCameraPaused)
                maybeEmitConnected()
            }
        case .renegotiate:
            if context.isPolite {
                try await negotiate(iceRestart: false)
            }
        case .iceComplete:
            return
        case .bye:
            emit(.closed)
            await closeCurrent(reason: "remote_bye", sendBye: false, finishStream: true, releasePreview: true)
        case .unknown:
            return
        }
    }

    private func handleDescription(_ item: RemoteRTCSignalItem) async throws {
        guard let peerConnection, let context = currentContext else { return }
        let decoded = try RTCSignalPayloadCodec.sessionDescription(from: item.data)
        guard let type = rtcSdpType(decoded.type), !decoded.sdp.isEmpty else {
            throw IMAPIError.server("视频协商信息无效")
        }
        let description = RTCSessionDescription(type: type, sdp: decoded.sdp)
        let readyForOffer = !makingOffer
            && (peerConnection.signalingState == .stable || isSettingRemoteAnswerPending)
        let offerCollision = type == .offer && !readyForOffer
        ignoreOffer = !context.isPolite && offerCollision
        if ignoreOffer { return }
        if type == .offer {
            adoptRemoteNegotiationIDIfNeeded(item.negotiationID)
        }
        if offerCollision {
            try await setLocalDescription(
                RTCSessionDescription(type: .rollback, sdp: ""),
                peerConnection: peerConnection
            )
        }
        guard type == .offer || acceptsNegotiation(item.negotiationID) else { return }
        isSettingRemoteAnswerPending = type == .answer
        defer {
            if type == .answer {
                isSettingRemoteAnswerPending = false
            }
        }
        try await setRemoteDescription(description, peerConnection: peerConnection)
        videoDebug("remote_description_set type=\(decoded.type)")
        try await flushPendingRemoteCandidates()
        if type == .offer {
            let answer = try await createAnswer(peerConnection: peerConnection)
            try await setLocalDescription(answer, peerConnection: peerConnection)
            try await sendDescription(answer, kind: .answer)
            videoDebug("answer_enqueued")
        }
    }

    private func adoptRemoteNegotiationIDIfNeeded(_ remoteNegotiationID: String) {
        let normalized = remoteNegotiationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != negotiationID else { return }
        negotiationID = normalized
        remoteCandidateKeys.removeAll()
        videoDebug("negotiation_adopted source=remote_offer")
    }

    private func acceptsRemoteSignal(_ item: RemoteRTCSignalItem, context: VideoMediaSessionContext) -> Bool {
        guard item.callID.isEmpty || item.callID == context.callID else {
            videoDebug("signal_ignored reason=call_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let fromUID = item.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fromUID.isEmpty || fromUID == context.peerUID else {
            videoDebug("signal_ignored reason=from_uid_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let toUID = item.toUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard toUID.isEmpty || toUID == context.localUID else {
            videoDebug("signal_ignored reason=to_uid_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let fromDevice = item.fromDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fromDevice.isEmpty || fromDevice == context.peerDeviceID else {
            videoDebug("signal_ignored reason=from_device_mismatch kind=\(item.kind.rawValue) fromHash=\(Self.shortStableHash(fromDevice)) peerHash=\(Self.shortStableHash(context.peerDeviceID))")
            return false
        }
        let targetDevice = item.toDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetDevice.isEmpty || targetDevice == context.localDeviceID else {
            videoDebug("signal_ignored reason=target_device_mismatch kind=\(item.kind.rawValue) targetHash=\(Self.shortStableHash(targetDevice)) localHash=\(Self.shortStableHash(context.localDeviceID))")
            return false
        }
        return true
    }

    private func acceptsNegotiation(_ remoteNegotiationID: String) -> Bool {
        let normalized = remoteNegotiationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty || normalized == negotiationID else {
            videoDebug("signal_ignored reason=negotiation_mismatch remote=\(Self.shortStableHash(normalized)) local=\(Self.shortStableHash(negotiationID))")
            return false
        }
        return true
    }

    private func handleCandidates(_ data: [String: JSONValue]) async throws {
        let candidates = try RTCSignalPayloadCodec.candidates(from: data)
        if !candidates.isEmpty {
            videoDebug("remote_candidates_received count=\(candidates.count)")
        }
        for item in candidates {
            let candidate = RTCIceCandidate(
                sdp: item.candidate,
                sdpMLineIndex: Int32(item.sdpMLineIndex ?? 0),
                sdpMid: item.sdpMid
            )
            let key = remoteCandidateKey(candidate)
            guard remoteCandidateKeys.insert(key).inserted else {
                videoDebug("remote_candidate_ignored reason=duplicate")
                continue
            }
            guard let peerConnection else { return }
            if peerConnection.remoteDescription == nil {
                pendingRemoteCandidates.append(candidate)
            } else {
                try await addIceCandidate(candidate, peerConnection: peerConnection)
            }
        }
    }

    private func flushPendingRemoteCandidates() async throws {
        guard let peerConnection else { return }
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in candidates {
            try await addIceCandidate(candidate, peerConnection: peerConnection)
        }
    }

    func negotiate(iceRestart: Bool) async throws {
        guard let peerConnection else { return }
        guard peerConnection.signalingState == .stable else { return }
        makingOffer = true
        defer { makingOffer = false }
        if iceRestart {
            peerConnection.restartIce()
            negotiationID = "neg-\(UUID().uuidString.lowercased())"
            sequence = 0
            remoteCandidateKeys.removeAll()
        }
        let offer = try await createOffer(peerConnection: peerConnection, iceRestart: iceRestart)
        try await setLocalDescription(offer, peerConnection: peerConnection)
        try await sendDescription(offer, kind: .offer)
        emit(.signaling)
    }

    private func sendDescription(_ description: RTCSessionDescription, kind: RemoteRTCSignalKind) async throws {
        try await sendSignal(
            kind: kind,
            data: RTCSignalPayloadCodec.sessionDescriptionData(type: kind.rawValue, sdp: description.sdp)
        )
    }

    func sendCandidate(_ candidate: RTCIceCandidate) async {
        let value = RemoteRTCIceCandidateSignalData(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex),
            usernameFragment: nil
        )
        do {
            try await sendSignal(kind: .candidate, data: RTCSignalPayloadCodec.candidateData([value]))
        } catch {
            // A full bounded outbox is a call-level reliability failure. Never
            // silently discard a candidate that cannot be retained.
            emit(.failed)
        }
    }

    func sendSignal(kind: RemoteRTCSignalKind, data: [String: JSONValue]) async throws {
        guard let context = currentContext else { return }
        sequence += 1
        let envelope = RemoteRTCSignalEnvelope(
            protocolVersion: RTCDeviceCapabilities.protocolVersion,
            messageID: UUID().uuidString.lowercased(),
            seq: sequence,
            negotiationID: negotiationID,
            callID: context.callID,
            toUID: context.peerUID,
            toDevice: context.peerDeviceID,
            kind: kind,
            data: data,
            sentAt: ISO8601DateFormatter().string(from: Date())
        )
        try signalOutbox.enqueue(envelope)
        videoDebug(
            "signal_enqueued kind=\(kind.rawValue) pending=\(signalOutbox.pending.count) peerDeviceHash=\(Self.shortStableHash(context.peerDeviceID))"
        )
        do {
            try await flushSignalOutbox()
        } catch {
            // Retryable critical signaling stays queued with its original
            // message_id and seq. A later critical envelope may supersede an
            // unsent best-effort media_state to keep sequence order monotonic.
            videoDebug(
                "signal_flush_deferred kind=\(kind.rawValue) pending=\(signalOutbox.pending.count) error=\(Self.safeErrorLabel(error))"
            )
            emit(.reconnecting)
        }
    }

    func flushSignalOutbox() async throws {
        guard !isFlushingSignalOutbox, let context = currentContext else { return }
        isFlushingSignalOutbox = true
        defer { isFlushingSignalOutbox = false }
        while let envelope = signalOutbox.pending.first {
            do {
                _ = try await context.postSignal(envelope, signalState.rtcToken)
                signalOutbox.markDelivered(messageID: envelope.messageID)
                videoDebug(
                    "signal_delivered kind=\(envelope.kind.rawValue) pending=\(signalOutbox.pending.count)"
                )
            } catch {
                videoDebug(
                    "signal_delivery_failed kind=\(envelope.kind.rawValue) error=\(Self.safeErrorLabel(error))"
                )
                if RTCVideoSignalFailurePolicy.shouldDropBestEffort(kind: envelope.kind, after: error) {
                    signalOutbox.markDelivered(messageID: envelope.messageID)
                    videoDebug(
                        "signal_best_effort_dropped kind=\(envelope.kind.rawValue) pending=\(signalOutbox.pending.count)"
                    )
                    continue
                }
                guard RTCVideoSignalFailurePolicy.isAuthoritativeTerminal(error) else {
                    throw error
                }
                signalOutbox.reset()
                emit(.serverSignalTerminal)
                await closeCurrent(
                    reason: "server_signal_terminal",
                    sendBye: false,
                    finishStream: true,
                    releasePreview: true
                )
                return
            }
        }
    }

    private func createOffer(peerConnection: RTCPeerConnection, iceRestart: Bool) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
                "IceRestart": iceRestart ? "true" : "false"
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: IMAPIError.server("视频协商创建失败"))
                }
            }
        }
    }

    private func createAnswer(peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: IMAPIError.server("视频协商应答失败"))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func remoteCandidateKey(_ candidate: RTCIceCandidate) -> String {
        [
            candidate.sdp.trimmingCharacters(in: .whitespacesAndNewlines),
            candidate.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(candidate.sdpMLineIndex)
        ].joined(separator: "|")
    }

    private func rtcSdpType(_ value: String) -> RTCSdpType? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "offer": return .offer
        case "answer": return .answer
        default: return nil
        }
    }
}
#endif

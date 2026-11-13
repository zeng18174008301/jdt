import AVFoundation
import Foundation

// WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: keep system call frameworks out unless a build explicitly enables CallKit.
#if WDT_ENABLE_CALLKIT && canImport(CallKit)
@preconcurrency import CallKit
#endif

#if WDT_ENABLE_CALLKIT && canImport(PushKit)
@preconcurrency import PushKit
#endif
// WDT_IOS1_CALLKIT_CN_POLICY_20260923_END

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
@MainActor
extension WebRTCVoiceMediaClient {
    func startSignalPolling(context: VoiceMediaSessionContext) {
        signalPollTask?.cancel()
        signalState.invalidatePolling()
        let generation = signalState.generation
        let pollSessionEpoch = sessionEpoch
        let pollCallID = context.callID
        signalPollTask = Task { @MainActor [weak self] in
            // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
            var pollingBackoff = RTCSignalPollingBackoffState()
            // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
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
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    let pollStartedAt = DispatchTime.now().uptimeNanoseconds
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    let page = try await context.pollSignals(cursor, token)
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    let pollElapsed = DispatchTime.now().uptimeNanoseconds - pollStartedAt
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    try Task.checkCancellation()
                    guard self.isCurrentSignalSession(
                        generation: generation,
                        sessionEpoch: pollSessionEpoch,
                        callID: pollCallID
                    ) else { break }
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    pollingBackoff.reset()
                    let next = page.nextCursor.trimmingCharacters(in: .whitespacesAndNewlines)
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                    if !page.items.isEmpty {
                        let kinds = page.items.map(\.kind.rawValue).joined(separator: ",")
                        self.rtcDebug("signal_poll_v2 items=\(page.items.count) kinds=\(kinds) cursorAdvanced=\(!page.nextCursor.isEmpty && page.nextCursor != cursor)")
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
                        try await self.handleRemoteSignal(item)
                        guard self.isCurrentSignalSession(
                            generation: generation,
                            sessionEpoch: pollSessionEpoch,
                            callID: pollCallID
                        ) else {
                            throw CancellationError()
                        }
                        self.signalState.markProcessed(item.messageID)
                    }
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
                    }
                    try? await self.flushSignalOutbox()
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    if let emptyDelay = RTCSignalPollingBackoffPolicy.quickEmptyDelayNanoseconds(
                        itemCount: page.items.count,
                        previousCursor: cursor,
                        nextCursor: next,
                        elapsedNanoseconds: pollElapsed,
                        isConnected: self.hasConnected && self.isICEConnected
                    ) {
                        self.rtcDebug("signal_poll_v2_quick_empty_delay elapsed_ms=\(pollElapsed / 1_000_000) delay_ms=\(emptyDelay / 1_000_000) connected=\(self.hasConnected && self.isICEConnected)")
                        try? await Task.sleep(nanoseconds: emptyDelay)
                    }
                    // JHT_MOD_END IOS_RTC_REQUEST_BACKOFF_20260911
                } catch is CancellationError {
                    break
                } catch {
                    self.rtcDebug("signal_poll_v2_failed error=\(Self.safeErrorLabel(error))")
                    self.emit(.iceDisconnected)
                    // JHT_MOD_BEGIN IOS_RTC_REQUEST_BACKOFF_20260911
                    if RTCSignalPollingBackoffPolicy.shouldStopPolling(after: error) {
                        self.rtcDebug("signal_poll_v2_stop error=\(Self.safeErrorLabel(error))")
                        break
                    }
                    let delay = pollingBackoff.recordFailureAndDelayNanoseconds(stableKey: pollCallID, error: error)
                    self.rtcDebug("signal_poll_v2_backoff delay_ms=\(delay / 1_000_000)")
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

    func createAndSendOffer(iceRestart: Bool) async throws {
        guard let peerConnection else {
            throw IMAPIError.server("语音 PeerConnection 未就绪")
        }
        if iceRestart {
            negotiationID = Self.makeNegotiationID()
            sequence = 0
            remoteCandidateKeys.removeAll()
            peerConnection.restartIce()
        }
        let offer = try await makeOffer(peerConnection: peerConnection, iceRestart: iceRestart)
        try Task.checkCancellation()
        try await setLocalDescription(offer, peerConnection: peerConnection)
        try Task.checkCancellation()
        emit(.localDescriptionSet)
        try await postSessionDescription(offer, kind: .offer)
        try Task.checkCancellation()
        rtcDebug("offer_sent iceRestart=\(iceRestart)")
    }

    private func createAndSendAnswer() async throws {
        guard let peerConnection else {
            throw IMAPIError.server("语音 PeerConnection 未就绪")
        }
        let answer = try await makeAnswer(peerConnection: peerConnection)
        try await setLocalDescription(answer, peerConnection: peerConnection)
        emit(.localDescriptionSet)
        try await postSessionDescription(answer, kind: .answer)
        rtcDebug("answer_sent")
    }

    private func handleRemoteSignal(_ item: RemoteRTCSignalItem) async throws {
        guard let context = currentContext else { return }
        guard acceptsRemoteSignal(item, context: context) else { return }
        rtcDebug("signal_handle kind=\(item.kind.rawValue) fromDeviceHash=\(Self.shortStableHash(item.fromDevice)) dataKeys=\(item.data.keys.sorted().joined(separator: ","))")
        switch item.kind {
        case .offer:
            guard !context.isCaller else {
                rtcDebug("signal_ignored reason=caller_received_offer")
                return
            }
            adoptRemoteNegotiationIDIfNeeded(item.negotiationID)
            try await handleRemoteSessionDescription(item.data, expectedType: "offer")
            try await createAndSendAnswer()
        case .answer:
            guard context.isCaller else {
                rtcDebug("signal_ignored reason=callee_received_answer")
                return
            }
            guard acceptsNegotiation(item.negotiationID) else { return }
            try await handleRemoteSessionDescription(item.data, expectedType: "answer")
        case .candidate:
            guard acceptsNegotiation(item.negotiationID) else { return }
            try await handleRemoteCandidates(item.data)
        case .iceRestart:
            if context.isCaller {
                scheduleRecovery(graceSeconds: 0, trigger: "peer_request")
            }
        case .iceComplete, .renegotiate, .mediaState:
            return
        case .bye:
            emit(.closed)
            await closeCurrent(reason: "remote_bye", sendBye: false, finishStream: true)
        case .unknown:
            return
        }
    }

    private func handleRemoteSessionDescription(_ data: [String: JSONValue], expectedType: String) async throws {
        guard let peerConnection else {
            throw IMAPIError.server("语音 PeerConnection 未就绪")
        }
        let decoded = try RTCSignalPayloadCodec.sessionDescription(from: data)
        guard decoded.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedType,
              let type = rtcSdpType(from: decoded.type),
              !decoded.sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.server("语音信令 SDP 无效")
        }
        let description = RTCSessionDescription(type: type, sdp: decoded.sdp)
        try await setRemoteDescription(description, peerConnection: peerConnection)
        rtcDebug("remote_description_set type=\(expectedType)")
        emit(.remoteDescriptionSet)
        try await flushPendingRemoteCandidates()
    }

    private func adoptRemoteNegotiationIDIfNeeded(_ remoteNegotiationID: String) {
        let normalized = remoteNegotiationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != negotiationID else { return }
        negotiationID = normalized
        remoteCandidateKeys.removeAll()
        rtcDebug("negotiation_adopted source=remote_offer")
    }

    private func acceptsRemoteSignal(_ item: RemoteRTCSignalItem, context: VoiceMediaSessionContext) -> Bool {
        guard item.callID.isEmpty || item.callID == context.callID else {
            rtcDebug("signal_ignored reason=call_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let fromUID = item.fromUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fromUID.isEmpty || fromUID == context.peerUID else {
            rtcDebug("signal_ignored reason=from_uid_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let toUID = item.toUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard toUID.isEmpty || toUID == context.localUID else {
            rtcDebug("signal_ignored reason=to_uid_mismatch kind=\(item.kind.rawValue)")
            return false
        }
        let fromDevice = item.fromDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fromDevice.isEmpty || fromDevice == context.peerDeviceID else {
            rtcDebug("signal_ignored reason=from_device_mismatch kind=\(item.kind.rawValue) fromHash=\(Self.shortStableHash(fromDevice)) peerHash=\(Self.shortStableHash(context.peerDeviceID))")
            return false
        }
        let targetDevice = item.toDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetDevice.isEmpty || targetDevice == context.localDeviceID else {
            rtcDebug("signal_ignored reason=target_device_mismatch kind=\(item.kind.rawValue) targetHash=\(Self.shortStableHash(targetDevice)) localHash=\(Self.shortStableHash(context.localDeviceID))")
            return false
        }
        return true
    }

    private func acceptsNegotiation(_ remoteNegotiationID: String) -> Bool {
        let normalized = remoteNegotiationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty || normalized == negotiationID else {
            rtcDebug("signal_ignored reason=negotiation_mismatch remote=\(Self.shortStableHash(normalized)) local=\(Self.shortStableHash(negotiationID))")
            return false
        }
        return true
    }

    private func handleRemoteCandidates(_ data: [String: JSONValue]) async throws {
        let decoded = try RTCSignalPayloadCodec.candidates(from: data)
        if !decoded.isEmpty {
            rtcDebug("remote_candidates_received count=\(decoded.count)")
        }
        for candidate in decoded {
            let normalized = candidate.candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let rtcCandidate = RTCIceCandidate(
                sdp: normalized,
                sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
                sdpMid: candidate.sdpMid
            )
            let key = remoteCandidateKey(rtcCandidate)
            guard remoteCandidateKeys.insert(key).inserted else {
                rtcDebug("remote_candidate_ignored reason=duplicate")
                continue
            }
            try await addRemoteCandidateOrQueue(rtcCandidate)
        }
    }

    private func addRemoteCandidateOrQueue(_ candidate: RTCIceCandidate) async throws {
        guard let peerConnection else {
            throw IMAPIError.server("语音 PeerConnection 未就绪")
        }
        guard peerConnection.remoteDescription != nil else {
            pendingRemoteCandidates.append(candidate)
            rtcDebug("remote_candidate_queued pending=\(pendingRemoteCandidates.count)")
            return
        }
        try await addIceCandidate(candidate, peerConnection: peerConnection)
    }

    private func flushPendingRemoteCandidates() async throws {
        guard let peerConnection else { return }
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in candidates {
            try await addIceCandidate(candidate, peerConnection: peerConnection)
        }
        if !candidates.isEmpty {
            rtcDebug("remote_candidate_queue_flushed count=\(candidates.count)")
        }
    }

    private func makeOffer(peerConnection: RTCPeerConnection, iceRestart: Bool) async throws -> RTCSessionDescription {
        let constraints = offerAnswerConstraints(iceRestart: iceRestart)
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: IMAPIError.server("语音 offer 创建失败"))
                }
            }
        }
    }

    private func makeAnswer(peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = offerAnswerConstraints(iceRestart: false)
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: IMAPIError.server("语音 answer 创建失败"))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        rtcDebug("remote_candidate_added")
    }

    private func remoteCandidateKey(_ candidate: RTCIceCandidate) -> String {
        [
            candidate.sdp.trimmingCharacters(in: .whitespacesAndNewlines),
            candidate.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(candidate.sdpMLineIndex)
        ].joined(separator: "|")
    }

    private func offerAnswerConstraints(iceRestart: Bool) -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false",
                "IceRestart": iceRestart ? "true" : "false"
            ],
            optionalConstraints: nil
        )
    }

    private func postSessionDescription(_ description: RTCSessionDescription, kind: RemoteRTCSignalKind) async throws {
        try await postSignal(kind: kind, data: RTCSignalPayloadCodec.sessionDescriptionData(type: kind.rawValue, sdp: description.sdp))
    }

    func postCandidate(_ candidate: RTCIceCandidate) async {
        let signal = RemoteRTCIceCandidateSignalData(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex),
            usernameFragment: nil
        )
        pendingLocalCandidateSignals.append(signal)
        rtcDebug("local_candidate_buffered pending=\(pendingLocalCandidateSignals.count)")
        if pendingLocalCandidateSignals.count >= Self.localCandidateBatchMaxCount {
            await flushPendingLocalCandidates(reason: "batch_full")
        } else {
            scheduleLocalCandidateFlush()
        }
    }

    private func scheduleLocalCandidateFlush() {
        guard localCandidateFlushTask == nil,
              currentContext != nil,
              !pendingLocalCandidateSignals.isEmpty else { return }
        let epoch = sessionEpoch
        let callID = currentContext?.callID
        localCandidateFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.localCandidateBatchDelayNanoseconds)
            guard let self,
                  self.sessionEpoch == epoch,
                  self.currentContext?.callID == callID else { return }
            self.localCandidateFlushTask = nil
            await self.flushPendingLocalCandidates(reason: "batch_delay", cancelScheduledTask: false)
        }
    }

    func flushPendingLocalCandidates(
        reason: String,
        cancelScheduledTask: Bool = true
    ) async {
        if cancelScheduledTask {
            localCandidateFlushTask?.cancel()
            localCandidateFlushTask = nil
        }
        guard !pendingLocalCandidateSignals.isEmpty else { return }
        let candidates = pendingLocalCandidateSignals
        pendingLocalCandidateSignals.removeAll(keepingCapacity: true)
        do {
            try await postSignal(kind: .candidate, data: RTCSignalPayloadCodec.candidateData(candidates))
            rtcDebug("local_candidates_sent count=\(candidates.count) reason=\(reason)")
        } catch {
            rtcDebug("local_candidates_send_failed count=\(candidates.count) reason=\(reason)")
            emit(.iceDisconnected)
        }
    }

    func postSignal(kind: RemoteRTCSignalKind, data: [String: JSONValue]) async throws {
        guard let context = currentContext else { return }
        sequence += 1
        rtcDebug(
            "post_signal_start kind=\(kind.rawValue) room=\(Self.shortDebugID(context.roomID)) localDeviceSource=\(context.localDeviceSource) localDeviceHash=\(Self.shortStableHash(context.localDeviceID)) peerDeviceSource=\(context.peerDeviceSource) peerDeviceHash=\(Self.shortStableHash(context.peerDeviceID))"
        )
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
            sentAt: Self.currentRFC3339Timestamp()
        )
        try signalOutbox.enqueue(envelope)
        try await flushSignalOutbox()
    }

    private func flushSignalOutbox() async throws {
        guard !isFlushingSignalOutbox, currentContext != nil else { return }
        isFlushingSignalOutbox = true
        defer { isFlushingSignalOutbox = false }
        while let envelope = signalOutbox.pending.first {
            guard let context = currentContext else { return }
            do {
                _ = try await context.postSignal(envelope, signalState.rtcToken)
                signalOutbox.markDelivered(messageID: envelope.messageID)
                rtcDebug("signal_v2_delivered kind=\(envelope.kind.rawValue) pending=\(signalOutbox.pending.count)")
            } catch {
                rtcDebug("signal_v2_delivery_failed kind=\(envelope.kind.rawValue) error=\(Self.safeErrorLabel(error)) pending=\(signalOutbox.pending.count)")
                throw error
            }
        }
    }
}
#endif

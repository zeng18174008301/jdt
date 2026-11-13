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
    func scheduleCredentialRefresh(refreshAfter: String, expiresAt: String) {
        credentialRefreshTask?.cancel()
        guard let delay = RTCVideoCredentialSchedule.delay(
            refreshAfter: refreshAfter,
            expiresAt: expiresAt
        ) else {
            return
        }
        let epoch = sessionEpoch
        credentialRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.sessionEpoch == epoch,
                  self.currentContext != nil else {
                return
            }
            self.scheduleRecovery(graceSeconds: 0, trigger: "credential_schedule")
        }
    }

    func scheduleRecovery(graceSeconds: TimeInterval, trigger: String) {
        guard currentContext != nil,
              recoveryTask == nil,
              !isClosingCurrentSession else {
            return
        }
        // A scheduled credential rotation and a peer-requested restart can
        // begin while the old transport is still connected. Force this
        // recovery operation to refresh/apply the new lease instead of
        // treating the old connection as proof that no work is required.
        isICEConnected = false
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        let epoch = sessionEpoch
        recoveryBudget.startWindowIfNeeded()
        rtcDebug("recovery_scheduled issue=media_degrade_or_long_call_end trigger=\(trigger) attempts=\(recoveryBudget.attempts)")
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if graceSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
            }
            guard self.isCurrentRecovery(epoch: epoch, generation: generation),
                  !self.isICEConnected else {
                self.finishRecoveryTaskIfCurrent(generation: generation)
                return
            }
            await self.runRecoveryLoop(epoch: epoch, generation: generation)
        }
    }

    private func runRecoveryLoop(epoch: Int, generation: Int) async {
        while isCurrentRecovery(epoch: epoch, generation: generation), !isICEConnected {
            let now = Date()
            guard let attempt = recoveryBudget.claimAttempt(now: now) else {
                await exhaustRecoveryIfCurrent(epoch: epoch, generation: generation)
                return
            }
            rtcDebug("recovery_attempt_start attempt=\(attempt)")
            let remainingForAttempt = recoveryBudget.remainingWindow()
            guard remainingForAttempt > 0 else {
                await exhaustRecoveryIfCurrent(epoch: epoch, generation: generation)
                return
            }
            do {
                try await RTCVoiceRecoveryDeadline.run(timeout: remainingForAttempt) { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.refreshCredentialsAndRestart(epoch: epoch, generation: generation)
                }
            } catch RTCVoiceRecoveryDeadlineError.exceeded {
                rtcDebug("recovery_attempt_deadline_exceeded attempt=\(attempt)")
                await exhaustRecoveryIfCurrent(epoch: epoch, generation: generation)
                return
            } catch is CancellationError {
                finishRecoveryTaskIfCurrent(generation: generation)
                return
            } catch {
                rtcDebug("recovery_attempt_failed attempt=\(attempt) error=\(Self.safeErrorLabel(error))")
            }

            let wait = min(
                RTCVoiceRecoveryBudget.connectionAttemptTimeout,
                recoveryBudget.remainingWindow()
            )
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard isCurrentRecovery(epoch: epoch, generation: generation) else {
                return
            }
            if isICEConnected {
                finishRecoveryTaskIfCurrent(generation: generation)
                return
            }
            let retryDelay = min(
                RTCVoiceRecoveryBudget.retryDelay(afterAttempt: attempt),
                recoveryBudget.remainingWindow()
            )
            if retryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        finishRecoveryTaskIfCurrent(generation: generation)
    }

    private func refreshCredentialsAndRestart(epoch: Int, generation: Int) async throws {
        guard let context = currentContext,
              let peerConnection else {
            throw CancellationError()
        }
        let snapshot = RTCVoiceCredentialRefreshSnapshot(
            sessionEpoch: epoch,
            recoveryGeneration: generation,
            callID: context.callID,
            roomID: context.roomID,
            rtcToken: context.rtcToken
        )
        let refreshed = try await context.refreshIceCredentials(snapshot.rtcToken)
        try Task.checkCancellation()
        guard let liveContext = currentContext,
              snapshot.matches(
                sessionEpoch: sessionEpoch,
                recoveryGeneration: recoveryGeneration,
                callID: liveContext.callID,
                roomID: liveContext.roomID,
                rtcToken: liveContext.rtcToken
              ),
              self.peerConnection === peerConnection else {
            throw CancellationError()
        }
        try liveContext.icePolicy.validateReplacement(refreshed.icePolicy)
        let reboundToken = refreshed.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reboundToken.isEmpty else {
            throw IMAPIError.server("语音网络凭据不可用")
        }
        let configuration = peerConnection.configuration
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：ICE 重启刷新凭据时也不再强制 relay
        configuration.iceTransportPolicy = .all
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        configuration.iceServers = makeIceServers(refreshed.iceServers)
        guard !configuration.iceServers.isEmpty,
              peerConnection.setConfiguration(configuration) else {
            throw IMAPIError.server("语音 ICE 配置更新失败")
        }

        signalState.rebindToken(reboundToken)
        var reboundContext = liveContext
        reboundContext.rtcToken = reboundToken
        reboundContext.iceServers = refreshed.iceServers
        reboundContext.iceCredentialExpiresAt = refreshed.iceCredentialExpiresAt
        reboundContext.iceCredentialRefreshAfter = refreshed.iceCredentialRefreshAfter
        currentContext = reboundContext
        startSignalPolling(context: reboundContext)
        scheduleCredentialRefresh(
            refreshAfter: refreshed.iceCredentialRefreshAfter,
            expiresAt: refreshed.iceCredentialExpiresAt
        )

        if reboundContext.isCaller {
            try await createAndSendOffer(iceRestart: true)
        } else {
            try Task.checkCancellation()
            try await postSignal(
                kind: .iceRestart,
                data: RTCSignalPayloadCodec.iceRestartData()
            )
            try Task.checkCancellation()
        }
        rtcDebug(
            "recovery_credentials_applied relays=\(RTCVoiceIceServerSet.relayCount(refreshed.iceServers))"
        )
    }

    func markConnected() {
        let recovered = hasConnected && recoveryTask != nil
        isICEConnected = true
        hasConnected = true
        recoveryBudget.reset()
        if recoveryTask != nil {
            recoveryGeneration &+= 1
            recoveryTask?.cancel()
            recoveryTask = nil
        }
        if recovered {
            emit(.connectionRecovered)
        }
        startRemoteAudioReadinessProbe()
#if DEBUG
        startVoiceQualityProbe()
#endif
    }

    private func isCurrentRecovery(epoch: Int, generation: Int) -> Bool {
        !Task.isCancelled
            && sessionEpoch == epoch
            && recoveryGeneration == generation
            && currentContext != nil
            && !isClosingCurrentSession
    }

    private func finishRecoveryTaskIfCurrent(generation: Int) {
        if recoveryGeneration == generation {
            recoveryTask = nil
        }
    }

    private func exhaustRecoveryIfCurrent(epoch: Int, generation: Int) async {
        guard isCurrentRecovery(epoch: epoch, generation: generation) else { return }
        rtcDebug("recovery_exhausted issue=media_degrade_or_long_call_end attempts=\(recoveryBudget.attempts)")
        recoveryTask = nil
        emit(.recoveryExhausted)
        await closeCurrent(
            reason: "ice_recovery_failed",
            sendBye: false,
            finishStream: true
        )
    }
}
#endif

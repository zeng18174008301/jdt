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
    private func refreshCredentialsForCurrentRole() async throws {
        guard let context = currentContext else { return }
        guard RTCVideoCredentialRefreshAction.resolve(
            inBandRequest: false,
            inBandRefreshPending: inBandCredentialRefresh.isPending
        ) != .rejectOutOfBand else {
            return
        }
        switch RTCVideoICERestartPolicy.action(isCaller: context.isCaller) {
        case .restartAndOffer:
            try await refreshCredentialsAndRestartAsCaller()
        case .requestCallerRestart:
            try await refreshCredentialsAndRequestCallerRestart()
        }
    }

    private func applyRefreshedCredentials(
        inBandSignalRefresh: Bool = false
    ) async throws -> Bool {
        guard let context = currentContext, let peerConnection else { return false }
        guard refreshingCredentialSessionEpoch == nil else { return false }
        let refreshSnapshot = RTCVideoCredentialRefreshSnapshot(
            sessionEpoch: sessionEpoch,
            callID: context.callID,
            roomID: context.roomID,
            rtcToken: signalState.rtcToken
        )
        refreshingCredentialSessionEpoch = refreshSnapshot.sessionEpoch
        defer {
            if refreshingCredentialSessionEpoch == refreshSnapshot.sessionEpoch {
                refreshingCredentialSessionEpoch = nil
            }
        }
        let refreshed = try await context.refreshIceCredentials(refreshSnapshot.rtcToken)
        try Task.checkCancellation()
        guard let liveContext = currentContext,
              refreshSnapshot.matches(
                sessionEpoch: sessionEpoch,
                callID: liveContext.callID,
                roomID: liveContext.roomID,
                rtcToken: signalState.rtcToken
              ),
              self.peerConnection === peerConnection else {
            throw CancellationError()
        }
        try liveContext.icePolicy.validateReplacement(refreshed.icePolicy)
        let reboundToken = refreshed.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshed.iceServers.isEmpty, !reboundToken.isEmpty else {
            throw IMAPIError.server("视频网络凭据不可用")
        }
        let configuration = peerConnection.configuration
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：ICE 重启刷新凭据时也不再强制 relay
        configuration.iceTransportPolicy = .all
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        configuration.iceServers = makeIceServers(refreshed.iceServers)
        guard peerConnection.setConfiguration(configuration) else {
            throw IMAPIError.server("视频网络凭据更新失败")
        }
        // Token and ICE credentials are one atomic server generation. Rebind
        // before restarting any poll or signal operation; the old token is
        // never retained after this point.
        if inBandSignalRefresh {
            signalState.stageTokenRebind(reboundToken)
            inBandCredentialRefresh.request()
        } else {
            signalState.rebindToken(reboundToken)
        }
        qualityTelemetrySession?.updateToken(reboundToken)
        qualityTelemetrySession?.updateRouteCapability(refreshed.turnRouteTelemetry)
        var reboundContext = context
        reboundContext.rtcToken = reboundToken
        currentContext = reboundContext
        if !inBandSignalRefresh {
            startSignalPolling(context: reboundContext)
        }
        scheduleCredentialRefresh(
            refreshAfter: refreshed.iceCredentialRefreshAfter,
            expiresAt: refreshed.iceCredentialExpiresAt
        )
        try? await flushSignalOutbox()
        return true
    }

    func refreshCredentialsAndRestartAsCaller(
        inBandSignalRefresh: Bool = false
    ) async throws {
        guard currentContext?.isCaller == true else { return }
        switch RTCVideoCredentialRefreshAction.resolve(
            inBandRequest: inBandSignalRefresh,
            inBandRefreshPending: inBandCredentialRefresh.isPending
        ) {
        case .retryNegotiation:
            try await negotiate(iceRestart: true)
            return
        case .rejectOutOfBand:
            return
        case .refreshAndNegotiate:
            break
        }
        let didRefresh = try await applyRefreshedCredentials(
            inBandSignalRefresh: inBandSignalRefresh
        )
        guard didRefresh else {
            if inBandSignalRefresh {
                throw IMAPIError.server("视频网络凭据正在更新")
            }
            return
        }
        try await negotiate(iceRestart: true)
    }

    private func refreshCredentialsAndRequestCallerRestart() async throws {
        guard currentContext?.isPolite == true else { return }
        guard RTCVideoCredentialRefreshAction.resolve(
            inBandRequest: false,
            inBandRefreshPending: inBandCredentialRefresh.isPending
        ) != .rejectOutOfBand else {
            return
        }
        guard try await applyRefreshedCredentials() else { return }
        try await sendSignal(
            kind: .iceRestart,
            data: RTCSignalPayloadCodec.iceRestartData()
        )
    }

    func scheduleCredentialRefresh(refreshAfter: String, expiresAt: String) {
        credentialRefreshTask?.cancel()
        guard let delay = RTCVideoCredentialSchedule.delay(
            refreshAfter: refreshAfter,
            expiresAt: expiresAt
        ) else { return }
        credentialRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? await self?.refreshCredentialsForCurrentRole()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.refreshCredentialsForCurrentRole()
        }
    }
}

extension WebRTCVideoMediaClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let audioTracks = stream.audioTracks
        let videoTrack = stream.videoTracks.first
        Task { @MainActor [weak self] in
            for track in audioTracks where !(self?.remoteAudioTracks.contains { $0 === track } ?? true) {
                track.isEnabled = true
                self?.remoteAudioTracks.append(track)
                self?.remoteAudioTrackReady = true
                self?.emit(.remoteAudioTrackReady)
                self?.startMediaReadinessProbe()
                self?.maybeEmitConnected()
            }
            if let videoTrack {
                self?.bindRemoteVideoTrack(videoTrack)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.videoDebug("ice_state=\(String(describing: newState))")
            switch newState {
            case .checking:
                self.emit(.connecting)
            case .connected, .completed:
                self.iceConnected = true
                self.reconnectTask?.cancel()
                self.startMediaReadinessProbe()
                self.maybeEmitConnected()
                try? await self.flushSignalOutbox()
            case .disconnected:
                self.iceConnected = false
                self.awaitingMediaRecovery = self.connectedEmitted
                self.remoteAudioRTPReady = false
                self.remoteVideoFrameReady = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.lastInboundVideoBytes = 0
                self.lastInboundVideoPackets = 0
                self.lastInboundVideoFrames = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.rearmRemoteFirstFrameObserver()
                self.emit(.reconnecting)
                self.scheduleReconnect()
            case .failed:
                self.iceConnected = false
                self.awaitingMediaRecovery = self.connectedEmitted
                self.remoteAudioRTPReady = false
                self.remoteVideoFrameReady = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.lastInboundVideoBytes = 0
                self.lastInboundVideoPackets = 0
                self.lastInboundVideoFrames = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.rearmRemoteFirstFrameObserver()
                self.emit(.reconnecting)
                self.scheduleReconnect()
            case .closed:
                self.emit(.closed)
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            try? await self?.sendSignal(kind: .iceComplete, data: RTCSignalPayloadCodec.iceCompleteData)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.videoDebug("local_candidate_generated")
            await self?.sendCandidate(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            self?.videoDebug("peer_connection_state=\(String(describing: newState))")
            switch newState {
            case .connecting:
                self?.emit(.connecting)
            case .connected:
                self?.iceConnected = true
                self?.startMediaReadinessProbe()
                self?.maybeEmitConnected()
                try? await self?.flushSignalOutbox()
            case .disconnected:
                self?.iceConnected = false
                self?.awaitingMediaRecovery = self?.connectedEmitted == true
                self?.remoteAudioRTPReady = false
                self?.remoteVideoFrameReady = false
                self?.lastInboundAudioBytes = 0
                self?.lastInboundAudioPackets = 0
                self?.lastInboundVideoBytes = 0
                self?.lastInboundVideoPackets = 0
                self?.lastInboundVideoFrames = 0
                if let self { self.mediaReadinessGeneration &+= 1 }
                self?.mediaReadinessTask?.cancel()
                self?.mediaReadinessTask = nil
                self?.rearmRemoteFirstFrameObserver()
                self?.emit(.reconnecting)
            case .failed:
                self?.iceConnected = false
                self?.awaitingMediaRecovery = self?.connectedEmitted == true
                self?.remoteAudioRTPReady = false
                self?.remoteVideoFrameReady = false
                self?.lastInboundAudioBytes = 0
                self?.lastInboundAudioPackets = 0
                self?.lastInboundVideoBytes = 0
                self?.lastInboundVideoPackets = 0
                self?.lastInboundVideoFrames = 0
                if let self { self.mediaReadinessGeneration &+= 1 }
                self?.mediaReadinessTask?.cancel()
                self?.mediaReadinessTask = nil
                self?.rearmRemoteFirstFrameObserver()
                self?.emit(.failed)
            case .closed:
                self?.emit(.closed)
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        Task { @MainActor [weak self] in
            if let videoTrack = transceiver.receiver.track as? RTCVideoTrack {
                self?.bindRemoteVideoTrack(videoTrack)
            } else if let audioTrack = transceiver.receiver.track as? RTCAudioTrack {
                audioTrack.isEnabled = true
                if !(self?.remoteAudioTracks.contains { $0 === audioTrack } ?? true) {
                    self?.remoteAudioTracks.append(audioTrack)
                }
                self?.remoteAudioTrackReady = true
                self?.emit(.remoteAudioTrackReady)
                self?.startMediaReadinessProbe()
                self?.maybeEmitConnected()
            }
        }
    }
}
#endif

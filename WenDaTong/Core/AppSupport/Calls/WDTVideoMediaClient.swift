import AVFoundation
import Foundation
import CoreFoundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

typealias RTCVideoSignalSender = @MainActor (_ envelope: RemoteRTCSignalEnvelope, _ rtcToken: String) async throws -> RemoteRTCSignalPostResult
typealias RTCVideoSignalPoller = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> RemoteRTCSignalItemsData
typealias RTCVideoSignalAcknowledger = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> Void
typealias RTCIceCredentialRefresher = @MainActor (_ rtcToken: String) async throws -> RemoteRTCIceCredentials

struct VideoMediaSessionContext {
    let callID: String
    let roomID: String
    var rtcToken: String
    let direction: String
    let localUID: String
    let localDeviceID: String
    let peerUID: String
    let peerDeviceID: String
    let iceServers: [RemoteRTCIceServer]
    let iceCredentialExpiresAt: String
    let iceCredentialRefreshAfter: String
    var turnRouteTelemetry: RemoteRTCTurnRouteTelemetry? = nil
    var icePolicy: RTCIcePolicy = .legacy
    let postSignal: RTCVideoSignalSender
    let pollSignals: RTCVideoSignalPoller
    let acknowledgeSignals: RTCVideoSignalAcknowledger
    let refreshIceCredentials: RTCIceCredentialRefresher
    let reportQuality: RTCQualityReporter

    var isCaller: Bool {
        let value = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("呼出") || value.contains("caller") || value.contains("outgoing")
    }

    var isPolite: Bool { !isCaller }
}

@MainActor
protocol VideoMediaClient: AnyObject {
    var isAvailable: Bool { get }
    var cameraAvailable: Bool { get }

    func preparePreview(preferFrontCamera: Bool) async throws
    func start(context: VideoMediaSessionContext, cameraEnabled: Bool) async throws -> AsyncStream<RTCVideoMediaEvent>
    func setMuted(_ isMuted: Bool) async
    func setSpeakerEnabled(_ isEnabled: Bool) async throws
    func setCameraEnabled(_ isEnabled: Bool) async throws
    func switchCamera() async throws
    func downgradeToAudio() async throws
    func applicationDidEnterBackground() async
    func applicationWillEnterForeground() async throws
    func reconcileAudioSessionAfterSystemEvent() async throws
    func stop(reason: String) async
}

@MainActor
final class NoopVideoMediaClient: VideoMediaClient {
    var isAvailable: Bool { false }
    var cameraAvailable: Bool { false }

    func preparePreview(preferFrontCamera: Bool) async throws {
        throw IMAPIError.server("当前设备不支持视频通话")
    }

    func start(context: VideoMediaSessionContext, cameraEnabled: Bool) async throws -> AsyncStream<RTCVideoMediaEvent> {
        throw IMAPIError.server("当前设备不支持视频通话")
    }

    func setMuted(_ isMuted: Bool) async {}
    func setSpeakerEnabled(_ isEnabled: Bool) async throws {
        throw IMAPIError.server("当前设备不支持视频通话音频路由")
    }
    func setCameraEnabled(_ isEnabled: Bool) async throws {}
    func switchCamera() async throws {}
    func downgradeToAudio() async throws {}
    func applicationDidEnterBackground() async {}
    func applicationWillEnterForeground() async throws {}
    func reconcileAudioSessionAfterSystemEvent() async throws {}
    func stop(reason: String) async {}
}

#if canImport(WebRTC)

private final class RTCVideoFirstFrameObserver: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var observed = false
    private let onFirstFrame: (Int, Int, Int) -> Void

    init(onFirstFrame: @escaping (Int, Int, Int) -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {}

    func reset() {
        lock.lock()
        observed = false
        lock.unlock()
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard !observed else {
            lock.unlock()
            return
        }
        observed = true
        lock.unlock()
        onFirstFrame(Int(frame.width), Int(frame.height), Int(frame.rotation.rawValue))
    }
}

@MainActor
final class WebRTCVideoMediaClient: NSObject, VideoMediaClient {
    private let factory: RTCPeerConnectionFactory
    var currentContext: VideoMediaSessionContext?
    private(set) var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoSource: RTCVideoSource?
    private(set) var localVideoTrack: RTCVideoTrack?
    var remoteAudioTracks: [RTCAudioTrack] = []
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteFirstFrameObserver: RTCVideoFirstFrameObserver?
    private var capturer: RTCCameraVideoCapturer?
    private var selectedPosition: AVCaptureDevice.Position = .front
    var cameraEnabledIntent = true
    private var isCapturing = false
    private var isApplicationBackgrounded = false
    var activeMediaMode = "video"
    var signalPollTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var credentialRefreshTask: Task<Void, Never>?
    var mediaReadinessTask: Task<Void, Never>?
    var mediaReadinessGeneration = 0
    private(set) var qualityTelemetrySession: RTCQualityTelemetrySession?
    private var eventContinuation: AsyncStream<RTCVideoMediaEvent>.Continuation?
    var pendingRemoteCandidates: [RTCIceCandidate] = []
    var remoteCandidateKeys: Set<String> = []
    var signalState = RTCVideoSignalRuntimeState(rtcToken: "")
    var inBandCredentialRefresh = RTCVideoInBandCredentialRefreshState()
    var signalOutbox = RTCVideoSignalOutbox()
    var isFlushingSignalOutbox = false
    var refreshingCredentialSessionEpoch: Int?
    private(set) var sessionEpoch = 0
    private var isClosingCurrentSession = false
    var sequence = 0
    var negotiationID = "neg-\(UUID().uuidString.lowercased())"
    var makingOffer = false
    var ignoreOffer = false
    var isSettingRemoteAnswerPending = false
    var iceConnected = false
    var remoteAudioTrackReady = false
    var remoteAudioRTPReady = false
    var remoteVideoFrameReady = false
    var remoteCameraPausedByContract = false
    var awaitingMediaRecovery = false
    var lastInboundAudioBytes: Int64 = 0
    var lastInboundAudioPackets: Int64 = 0
    var lastInboundVideoBytes: Int64 = 0
    var lastInboundVideoPackets: Int64 = 0
    var lastInboundVideoFrames: Int64 = 0
    var connectedEmitted = false
    private(set) var currentDebugID = ""
    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：跟踪视频实例音频会话所有权和启动阶段，避免旧实例误关新音频
    private var ownedAudioSessionEpoch: Int?
    // WDT_IOS1_AUDIO_ROUTE_20260921: keep explicit route intent when recovering.
    private var speakerEnabled = true
    private var mediaStartStage = "idle"
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束

    override init() {
        _ = WebRTCRuntime.isReady
        factory = RTCPeerConnectionFactory()
        super.init()
    }

    var isAvailable: Bool { WebRTCRuntime.isReady }

    var cameraAvailable: Bool {
        !RTCCameraVideoCapturer.captureDevices().isEmpty
    }

    func preparePreview(preferFrontCamera: Bool) async throws {
        guard isAvailable else { throw IMAPIError.server("当前设备不支持视频通话") }
        selectedPosition = preferFrontCamera ? .front : .back
        try createLocalVideoTrackIfNeeded()
        cameraEnabledIntent = true
        try await startCaptureIfNeeded()
        emit(.previewReady)
    }

    func start(context: VideoMediaSessionContext, cameraEnabled: Bool) async throws -> AsyncStream<RTCVideoMediaEvent> {
        if let existing = currentContext, existing.callID == context.callID {
            try existing.icePolicy.validateReplacement(context.icePolicy)
        }
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：不再因 relay policy 在启动前强制校验 TURN
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        await closeCurrent(reason: "restart", sendBye: false, finishStream: true, releasePreview: false)
        currentDebugID = Self.shortStableHash(context.callID)
        guard !context.callID.isEmpty, !context.roomID.isEmpty, !context.rtcToken.isEmpty else {
            throw IMAPIError.server("视频房间信息不完整")
        }
        guard !context.localDeviceID.isEmpty, !context.peerUID.isEmpty, !context.peerDeviceID.isEmpty else {
            throw IMAPIError.server("视频设备信息不完整")
        }
        let stream = AsyncStream<RTCVideoMediaEvent> { continuation in
            eventContinuation = continuation
        }
        currentContext = context
        sessionEpoch &+= 1
        signalState = RTCVideoSignalRuntimeState(rtcToken: context.rtcToken)
        inBandCredentialRefresh.reset()
        signalOutbox = RTCVideoSignalOutbox()
        negotiationID = "neg-\(UUID().uuidString.lowercased())"
        sequence = 0
        cameraEnabledIntent = cameraEnabled
        activeMediaMode = "video"
        iceConnected = false
        remoteAudioTrackReady = false
        remoteAudioRTPReady = false
        remoteVideoFrameReady = false
        remoteCameraPausedByContract = false
        awaitingMediaRecovery = false
        lastInboundAudioBytes = 0
        lastInboundAudioPackets = 0
        lastInboundVideoBytes = 0
        lastInboundVideoPackets = 0
        lastInboundVideoFrames = 0
        connectedEmitted = false

        do {
            videoDebug(
                "start role=\(context.isCaller ? "caller" : "callee") localDeviceHash=\(Self.shortStableHash(context.localDeviceID)) peerDeviceHash=\(Self.shortStableHash(context.peerDeviceID)) iceServers=\(context.iceServers.count) cameraIntent=\(cameraEnabled)"
            )
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：记录视频媒体启动阶段，便于真机失败定位
            mediaStartStage = "audio_category"
            try configureAudioSession()
            mediaStartStage = "peer_connection_create"
            try createPeerConnection(context: context)
            mediaStartStage = "quality_session_create"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            if RTCQualityTokenScope.hasWriteScope(context.rtcToken), let connection = peerConnection {
                qualityTelemetrySession = RTCQualityTelemetrySession(
                    rtcToken: context.rtcToken,
                    statsProvider: { [weak self, weak connection] in
                        guard let self, let connection else { return [] }
                        return await self.qualityStatRecords(for: connection)
                    },
                    reporter: context.reportQuality,
                    turnRouteTelemetry: context.turnRouteTelemetry,
                    sequenceProvider: {
                        RTCQualitySequenceLedger.shared.reserve(callKey: "\(context.roomID)|\(context.callID)|\(context.localUID)|\(context.isCaller)")
                    }
                )
            } else {
                qualityTelemetrySession = nil
            }
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "audio_track_create"
            try createLocalAudioTrack(context: context)
            mediaStartStage = "video_track_create"
            try createLocalVideoTrackIfNeeded()
            mediaStartStage = "video_track_add"
            try addLocalVideoTrack(context: context)
            mediaStartStage = "camera_start"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            let shouldCapture = RTCVideoCapturePolicy.shouldCapture(
                cameraEnabledIntent: cameraEnabled,
                isApplicationBackgrounded: isApplicationBackgrounded
            )
            var cameraUnavailableAtStart = false
            if shouldCapture {
                do {
                    try await startCaptureIfNeeded()
                } catch {
                    cameraEnabledIntent = false
                    localVideoTrack?.isEnabled = false
                    await stopCaptureIfNeeded()
                    cameraUnavailableAtStart = true
                }
            } else {
                await stopCaptureIfNeeded()
                localVideoTrack?.isEnabled = false
            }
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "signaling_start"
            startSignalPolling(context: context)
            mediaStartStage = "ice_credential_schedule"
            scheduleCredentialRefresh(
                refreshAfter: context.iceCredentialRefreshAfter,
                expiresAt: context.iceCredentialExpiresAt
            )
            if context.isCaller {
                mediaStartStage = "offer_create"
                try await negotiate(iceRestart: false)
            }
            mediaStartStage = "started"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            if cameraUnavailableAtStart || !shouldCapture {
                emit(cameraUnavailableAtStart ? .cameraUnavailable : .cameraPaused)
                try? await sendSignal(
                    kind: .mediaState,
                    data: RTCVideoMediaStatePayload.make(
                        cameraEnabled: false,
                        mediaMode: "video"
                    )
                )
            }
            return stream
        } catch {
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：只记录安全字段，不输出 SDP/ICE/token/userInfo
            videoDebug("start_failed stage=\(mediaStartStage) error=\(Self.safeErrorSummary(error))")
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            await closeCurrent(reason: "start_failed", sendBye: false, finishStream: true, releasePreview: true)
            throw error
        }
    }

    func setMuted(_ isMuted: Bool) async {
        localAudioTrack?.isEnabled = !isMuted
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN
    func setSpeakerEnabled(_ isEnabled: Bool) async throws {
        speakerEnabled = isEnabled
        guard currentContext != nil, peerConnection != nil, !isClosingCurrentSession else { return }
        try configureAudioSession()
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.overrideOutputAudioPort(isEnabled ? .speaker : .none)
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    func setCameraEnabled(_ isEnabled: Bool) async throws {
        let previousIntent = cameraEnabledIntent
        cameraEnabledIntent = isEnabled
        activeMediaMode = "video"
        guard capturer != nil, localVideoTrack != nil else { return }
        guard !isApplicationBackgrounded else {
            localVideoTrack?.isEnabled = false
            return
        }
        do {
            if isEnabled {
                try await startCaptureIfNeeded()
                localVideoTrack?.isEnabled = true
                emit(.cameraResumed)
            } else {
                localVideoTrack?.isEnabled = false
                await stopCaptureIfNeeded()
                emit(.cameraPaused)
            }
            try await sendSignal(
                kind: .mediaState,
                data: RTCVideoMediaStatePayload.make(
                    cameraEnabled: isEnabled,
                    mediaMode: "video"
                )
            )
        } catch {
            let resolvedIntent = RTCVideoCameraFailurePolicy.resolvedIntent(
                requestedEnabled: isEnabled,
                previousIntent: previousIntent
            )
            cameraEnabledIntent = resolvedIntent
            if resolvedIntent {
                try? await startCaptureIfNeeded()
                localVideoTrack?.isEnabled = isCapturing
            } else {
                localVideoTrack?.isEnabled = false
                await stopCaptureIfNeeded()
            }
            throw error
        }
    }

    func switchCamera() async throws {
        guard cameraAvailable else { throw IMAPIError.server("当前设备没有可切换的摄像头") }
        emit(.cameraSwitching)
        let previousPosition = selectedPosition
        selectedPosition = previousPosition == .front ? .back : .front
        guard capturer != nil, localVideoTrack != nil else {
            emit(.cameraSwitched)
            return
        }
        await stopCaptureIfNeeded()
        do {
            if cameraEnabledIntent, !isApplicationBackgrounded {
                try await startCaptureIfNeeded()
            }
            emit(.cameraSwitched)
        } catch {
            selectedPosition = previousPosition
            if cameraEnabledIntent, !isApplicationBackgrounded {
                try? await startCaptureIfNeeded()
            }
            emit(.cameraUnavailable)
            throw error
        }
    }

    func downgradeToAudio() async throws {
        activeMediaMode = "audio"
        cameraEnabledIntent = false
        localVideoTrack?.isEnabled = false
        await stopCaptureIfNeeded()
        emit(.cameraPaused)
        maybeEmitConnected()
        try await sendSignal(
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(
                cameraEnabled: false,
                microphoneEnabled: localAudioTrack?.isEnabled,
                mediaMode: "audio"
            )
        )
    }

    func applicationDidEnterBackground() async {
        isApplicationBackgrounded = true
        localVideoTrack?.isEnabled = false
        await stopCaptureIfNeeded()
        emit(.cameraPaused)
        try? await sendSignal(
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(
                cameraEnabled: false,
                mediaMode: activeMediaMode
            )
        )
        await qualityTelemetrySession?.applicationDidEnterBackground()
    }

    func applicationWillEnterForeground() async throws {
        isApplicationBackgrounded = false
        let shouldResumeVideo = activeMediaMode == "video" && cameraEnabledIntent
        if shouldResumeVideo {
            try await startCaptureIfNeeded()
            localVideoTrack?.isEnabled = true
            emit(.cameraResumed)
        }
        try await sendSignal(
            kind: .mediaState,
            data: RTCVideoMediaStatePayload.make(
                cameraEnabled: shouldResumeVideo,
                mediaMode: activeMediaMode
            )
        )
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN
    func reconcileAudioSessionAfterSystemEvent() async throws {
        guard currentContext != nil, peerConnection != nil, !isClosingCurrentSession else { return }
        try configureAudioSession()
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    func stop(reason: String) async {
        await closeCurrent(reason: reason, sendBye: true, finishStream: true, releasePreview: true)
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: share the voice client's balanced, idempotent audio ownership rule.
    private func configureAudioSession() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let options: AVAudioSession.CategoryOptions = speakerEnabled
            ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP]
        if session.category != AVAudioSession.Category.playAndRecord.rawValue || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, with: options)
        }
        if session.mode != AVAudioSession.Mode.videoChat.rawValue { try session.setMode(.videoChat) }
        if ownedAudioSessionEpoch != sessionEpoch {
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            ownedAudioSessionEpoch = sessionEpoch
        }
        session.isAudioEnabled = true
        mediaStartStage = "audio_session_ready"
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    private func createPeerConnection(context: VideoMediaSessionContext) throws {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        // JHT_MOD_BEGIN RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改开始：预热少量 ICE candidate，缩短初始连通等待
        configuration.iceCandidatePoolSize = 2
        // JHT_MOD_END RTC_CONNECT_LATENCY_STABILITY_20260915 - 修改结束
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：取消 iOS 强制中继，允许 host/srflx/relay 共同参与 ICE
        configuration.iceTransportPolicy = .all
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        configuration.iceServers = makeIceServers(context.iceServers)
        guard !configuration.iceServers.isEmpty else {
            throw IMAPIError.server("视频 ICE 配置缺失")
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw IMAPIError.server("视频连接初始化失败")
        }
        peerConnection = connection
    }

    func makeIceServers(_ servers: [RemoteRTCIceServer]) -> [RTCIceServer] {
        servers.compactMap { server in
            let urls = server.urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: server.username, credential: server.credential)
        }
    }

    private func createLocalAudioTrack(context: VideoMediaSessionContext) throws {
        guard let peerConnection else { throw IMAPIError.server("视频连接未就绪") }
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "audio-\(context.callID)")
        track.isEnabled = true
        guard peerConnection.add(track, streamIds: ["video-\(context.callID)"]) != nil else {
            throw IMAPIError.server("麦克风轨道创建失败")
        }
        localAudioTrack = track
        emit(.localTrackReady)
    }

    private func createLocalVideoTrackIfNeeded() throws {
        guard localVideoTrack == nil else { return }
        let source = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "video-\(UUID().uuidString)")
        track.isEnabled = true
        localVideoSource = source
        localVideoTrack = track
        self.capturer = capturer
        RTCVideoRenderRegistry.shared.setLocalTrack(track)
    }

    private func addLocalVideoTrack(context: VideoMediaSessionContext) throws {
        guard let peerConnection, let localVideoTrack else { throw IMAPIError.server("摄像头轨道未就绪") }
        guard peerConnection.add(localVideoTrack, streamIds: ["video-\(context.callID)"]) != nil else {
            throw IMAPIError.server("摄像头轨道创建失败")
        }
    }

    private func startCaptureIfNeeded() async throws {
        guard !isCapturing else { return }
        guard let capturer else { throw IMAPIError.server("摄像头未就绪") }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard !devices.isEmpty else { throw IMAPIError.server("当前设备没有可用摄像头") }
        let device = devices.first(where: { $0.position == selectedPosition }) ?? devices[0]
        selectedPosition = device.position
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats
            .filter({
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return size.width <= 1280 && size.height <= 720
            })
            .max(by: {
                let lhs = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let rhs = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return lhs.width * lhs.height < rhs.width * rhs.height
            }) ?? formats.first else {
            throw IMAPIError.server("摄像头格式不可用")
        }
        let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 24
        let fps = min(30, max(15, Int(maxFPS.rounded(.down))))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capturer.startCapture(with: device, format: format, fps: fps) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        isCapturing = true
        localVideoTrack?.isEnabled = true
    }

    func stopCaptureIfNeeded() async {
        guard isCapturing, let capturer else { return }
        await withCheckedContinuation { continuation in
            capturer.stopCapture {
                continuation.resume()
            }
        }
        isCapturing = false
    }

    func closeCurrent(
        reason: String,
        sendBye: Bool,
        finishStream: Bool,
        releasePreview: Bool
    ) async {
        guard !isClosingCurrentSession else { return }
        isClosingCurrentSession = true
        defer { isClosingCurrentSession = false }
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：在换代前确认音频会话所有权，旧实例不得误关新实例音频
        let shouldReleaseAudioSession = ownedAudioSessionEpoch == sessionEpoch
        ownedAudioSessionEpoch = nil
        mediaStartStage = "closed"
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        // Invalidate every suspended poll/refresh before the first await below.
        // A late response from the old call must never mutate a replacement call.
        sessionEpoch &+= 1
        let context = currentContext
        signalPollTask?.cancel()
        reconnectTask?.cancel()
        credentialRefreshTask?.cancel()
        mediaReadinessGeneration &+= 1
        mediaReadinessTask?.cancel()
        signalPollTask = nil
        reconnectTask = nil
        credentialRefreshTask = nil
        mediaReadinessTask = nil
        let qualitySession = qualityTelemetrySession
        qualityTelemetrySession = nil
        Task { @MainActor in await qualitySession?.stop() }
        if sendBye, context != nil {
            try? await sendSignal(kind: .bye, data: ["reason": .string(reason)])
        }
        await stopCaptureIfNeeded()
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        remoteAudioTracks.removeAll()
        remoteAudioTrackReady = false
        remoteAudioRTPReady = false
        remoteVideoFrameReady = false
        remoteCameraPausedByContract = false
        awaitingMediaRecovery = false
        lastInboundAudioBytes = 0
        lastInboundAudioPackets = 0
        lastInboundVideoBytes = 0
        lastInboundVideoPackets = 0
        lastInboundVideoFrames = 0
        if let remoteVideoTrack, let remoteFirstFrameObserver {
            remoteVideoTrack.remove(remoteFirstFrameObserver)
        }
        remoteFirstFrameObserver = nil
        remoteVideoTrack = nil
        pendingRemoteCandidates.removeAll()
        remoteCandidateKeys.removeAll()
        currentContext = nil
        signalState = RTCVideoSignalRuntimeState(rtcToken: "")
        inBandCredentialRefresh.reset()
        signalOutbox = RTCVideoSignalOutbox()
        isFlushingSignalOutbox = false
        refreshingCredentialSessionEpoch = nil
        if releasePreview {
            localVideoTrack?.isEnabled = false
            localVideoTrack = nil
            localVideoSource = nil
            capturer = nil
            RTCVideoRenderRegistry.shared.clear()
        } else {
            RTCVideoRenderRegistry.shared.setRemoteTrack(nil)
        }
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
        if shouldReleaseAudioSession {
            audioSession.isAudioEnabled = false
            try? audioSession.setActive(false)
        }
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        audioSession.unlockForConfiguration()
        if finishStream {
            eventContinuation?.finish()
            eventContinuation = nil
        }
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
        videoDebug("closed reason=\(reason) sendBye=\(sendBye) releasedAudio=\(shouldReleaseAudioSession)")
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        currentDebugID = ""
    }

    func emit(_ event: RTCVideoMediaEvent) {
        videoDebug("event=\(event.rawValue)")
        eventContinuation?.yield(event)
    }

    func bindRemoteVideoTrack(_ track: RTCVideoTrack) {
        guard remoteVideoTrack !== track else {
            rearmRemoteFirstFrameObserver()
            return
        }
        if let remoteVideoTrack, let remoteFirstFrameObserver {
            remoteVideoTrack.remove(remoteFirstFrameObserver)
        }
        remoteVideoTrack = track
        remoteVideoFrameReady = false
        lastInboundVideoBytes = 0
        lastInboundVideoPackets = 0
        lastInboundVideoFrames = 0
        track.isEnabled = true
        RTCVideoRenderRegistry.shared.setRemoteTrack(track)
        let epoch = sessionEpoch
        let observer = RTCVideoFirstFrameObserver { [weak self] width, height, rotation in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionEpoch == epoch,
                      self.remoteVideoTrack === track else { return }
                self.videoDebug("remote_first_frame width=\(width) height=\(height) rotation=\(rotation)")
                self.remoteVideoFrameReady = true
                self.emit(.remoteVideoTrackReady)
                self.maybeEmitConnected()
            }
        }
        remoteFirstFrameObserver = observer
        track.add(observer)
    }

    func rearmRemoteFirstFrameObserver() {
        remoteFirstFrameObserver?.reset()
    }

}

#endif

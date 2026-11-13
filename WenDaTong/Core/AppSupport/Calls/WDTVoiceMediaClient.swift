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
enum WebRTCRuntime {
    static let isReady: Bool = RTCInitializeSSL()
}

@MainActor
final class WebRTCVoiceMediaClient: NSObject, VoiceMediaClient {
    private let factory: RTCPeerConnectionFactory
    var currentContext: VoiceMediaSessionContext?
    private(set) var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTracks: [RTCAudioTrack] = []
    var signalPollTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var credentialRefreshTask: Task<Void, Never>?
    private var mediaReadinessTask: Task<Void, Never>?
    private var mediaReadinessGeneration = 0
    private var eventContinuation: AsyncStream<RTCVoiceMediaEvent>.Continuation?
    var pendingRemoteCandidates: [RTCIceCandidate] = []
    var remoteCandidateKeys: Set<String> = []
    var signalState = RTCVideoSignalRuntimeState(rtcToken: "")
    var signalOutbox = RTCVideoSignalOutbox()
    var pendingLocalCandidateSignals: [RemoteRTCIceCandidateSignalData] = []
    var localCandidateFlushTask: Task<Void, Never>?
    var isFlushingSignalOutbox = false
    private var currentDebugID: String = ""
    private(set) var sessionEpoch = 0
    var recoveryGeneration = 0
    var recoveryBudget = RTCVoiceRecoveryBudget()
    var isICEConnected = false
    var hasConnected = false
    private var lastInboundAudioBytes: Int64 = 0
    private var lastInboundAudioPackets: Int64 = 0
    var qualityProbeTask: Task<Void, Never>?
    var qualitySampleReducer = RTCQualitySampleReducer()
    var qualitySampleSequence: Int64 = 0
    private(set) var isClosingCurrentSession = false
    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：跟踪本实例音频会话所有权和启动阶段，便于接听失败定位
    private var ownedAudioSessionEpoch: Int?
    // WDT_IOS1_AUDIO_ROUTE_20260921: preserve receiver/speaker intent across recovery.
    private var speakerEnabled = true
    private var mediaStartStage = "idle"
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    var sequence = 0
    var negotiationID = WebRTCVoiceMediaClient.makeNegotiationID()
    static let localCandidateBatchDelayNanoseconds: UInt64 = 25_000_000
    static let localCandidateBatchMaxCount = 6

    override init() {
        _ = WebRTCRuntime.isReady
        factory = RTCPeerConnectionFactory()
        super.init()
    }

    var isAvailable: Bool { WebRTCRuntime.isReady }

    func start(context: VoiceMediaSessionContext) async throws -> AsyncStream<RTCVoiceMediaEvent> {
        if let existing = currentContext, existing.callID == context.callID {
            try existing.icePolicy.validateReplacement(context.icePolicy)
        }
        // JHT_MOD_BEGIN RTC_REMOVE_FORCED_RELAY_20260914 - 修改开始：不再因 relay policy 在启动前强制校验 TURN
        // JHT_MOD_END RTC_REMOVE_FORCED_RELAY_20260914 - 修改结束
        await closeCurrent(reason: "restart", sendBye: false, finishStream: true)
        currentDebugID = Self.shortDebugID(context.callID)
        guard !context.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !context.rtcToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.server("语音房间信息不完整")
        }
        guard !context.localDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.server("本机语音设备信息不完整")
        }
        guard !context.peerUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !context.peerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.server("对端语音设备信息不完整")
        }

        let stream = AsyncStream<RTCVoiceMediaEvent> { continuation in
            eventContinuation = continuation
        }

        do {
            currentContext = context
            sessionEpoch &+= 1
            recoveryGeneration &+= 1
            signalState = RTCVideoSignalRuntimeState(rtcToken: context.rtcToken)
            signalOutbox = RTCVideoSignalOutbox()
            pendingLocalCandidateSignals.removeAll(keepingCapacity: false)
            localCandidateFlushTask?.cancel()
            localCandidateFlushTask = nil
            isFlushingSignalOutbox = false
            sequence = 0
            negotiationID = Self.makeNegotiationID()
            recoveryBudget = RTCVoiceRecoveryBudget()
            isICEConnected = false
            hasConnected = false
            lastInboundAudioBytes = 0
            lastInboundAudioPackets = 0
            qualityProbeTask?.cancel()
            qualityProbeTask = nil
            qualitySampleReducer = RTCQualitySampleReducer()
            qualitySampleSequence = 0
            rtcDebug("start issue=media_degrade_or_long_call_end role=\(context.isCaller ? "caller" : "callee") iceServers=\(context.iceServers.count)")
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "audio_category"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            try configureAudioSession()
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "peer_connection_create"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            try createPeerConnection(context: context)
            emit(.roomJoined)
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "audio_track_create"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            try createLocalAudioTrack(context: context)
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "signaling_start"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            startSignalPolling(context: context)
            scheduleCredentialRefresh(
                refreshAfter: context.iceCredentialRefreshAfter,
                expiresAt: context.iceCredentialExpiresAt
            )
            if context.isCaller {
                // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
                mediaStartStage = "offer_create"
                // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
                try await createAndSendOffer(iceRestart: false)
            }
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            mediaStartStage = "started"
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            return stream
        } catch {
            // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
            rtcDebug("start_failed stage=\(mediaStartStage) error=\(Self.safeErrorSummary(error))")
            // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
            await closeCurrent(reason: "start_failed", sendBye: false, finishStream: true)
            throw error
        }
    }

    func setMuted(_ isMuted: Bool) async {
        localAudioTrack?.isEnabled = !isMuted
        rtcDebug("mute_changed muted=\(isMuted) localTrackEnabled=\(localAudioTrack?.isEnabled == true)")
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: route changes are local audio changes, never synthetic ICE failures.
    func setSpeakerEnabled(_ isEnabled: Bool) async {
        speakerEnabled = isEnabled
        guard currentContext != nil, peerConnection != nil, !isClosingCurrentSession else { return }
        do {
            try configureAudioSession()
            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            try session.overrideOutputAudioPort(isEnabled ? .speaker : .none)
            rtcDebug("speaker_route enabled=\(isEnabled)")
        } catch {
            rtcDebug("speaker_route_failed error=\(Self.safeErrorSummary(error))")
        }
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始：只恢复音频会话和既有扬声器意图，不改通话状态机
    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: recover only this live media owner, never a ringing/closed call.
    func reconcileAudioSessionAfterSystemEvent(speakerOn: Bool) async throws {
        guard currentContext != nil, peerConnection != nil, !isClosingCurrentSession else { return }
        speakerEnabled = speakerOn
        try configureAudioSession()
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let usingSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        let builtInOutput = session.currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
        if builtInOutput && usingSpeaker != speakerOn {
            try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        }
        rtcDebug("audio_session_reconciled speaker=\(speakerOn) route=\(audioRouteSummary())")
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END
    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束

    func stop(reason: String) async {
        await closeCurrent(reason: reason, sendBye: true, finishStream: true)
    }

    // WDT_IOS1_AUDIO_ROUTE_20260921_BEGIN: acquire one balanced activation per media epoch, not per route notification.
    private func configureAudioSession() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let options: AVAudioSession.CategoryOptions = speakerEnabled
            ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP]
        if session.category != AVAudioSession.Category.playAndRecord.rawValue || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, with: options)
        }
        if session.mode != AVAudioSession.Mode.voiceChat.rawValue { try session.setMode(.voiceChat) }
        if ownedAudioSessionEpoch != sessionEpoch {
            // Preferences belong to initial setup. Do not rebuild the audio graph on route feedback.
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            ownedAudioSessionEpoch = sessionEpoch
        }
        session.isAudioEnabled = true
        mediaStartStage = "audio_session_ready"
        let av = session.session
        rtcDebug("audio_session_ready route=\(audioRouteSummary()) sampleRate=\(av.sampleRate) ioBuffer=\(av.ioBufferDuration) inputs=\(av.inputNumberOfChannels) outputs=\(av.outputNumberOfChannels)")
    }
    // WDT_IOS1_AUDIO_ROUTE_20260921_END

    private func createPeerConnection(context: VoiceMediaSessionContext) throws {
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
            throw IMAPIError.server("语音 ICE 配置缺失")
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw IMAPIError.server("语音 PeerConnection 初始化失败")
        }
        self.peerConnection = peerConnection
        rtcDebug("peer_connection_created iceServers=\(configuration.iceServers.count) relays=\(RTCVoiceIceServerSet.relayCount(context.iceServers))")
    }

    func makeIceServers(_ servers: [RemoteRTCIceServer]) -> [RTCIceServer] {
        servers.compactMap { server in
            let urls = server.urls
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: server.username, credential: server.credential)
        }
    }

    private func createLocalAudioTrack(context: VoiceMediaSessionContext) throws {
        guard let peerConnection else {
            throw IMAPIError.server("语音 PeerConnection 未就绪")
        }
        let source = factory.audioSource(with: audioProcessingConstraints())
        let track = factory.audioTrack(with: source, trackId: "audio-\(context.callID)")
        track.isEnabled = true
        guard peerConnection.add(track, streamIds: ["voice-\(context.callID)"]) != nil else {
            throw IMAPIError.server("本地语音轨道创建失败")
        }
        localAudioTrack = track
        rtcDebug("local_audio_track_ready issue=media_degrade_or_long_call_end enabled=\(track.isEnabled) audioProcessing=default")
        emit(.localTrackReady)
    }

    // WDT_RTC_ISSUE2_MEDIA_DEGRADE_20260919_BEGIN: use WebRTC default audio processing, matching Android's empty constraints.
    private func audioProcessingConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
    }
    // WDT_RTC_ISSUE2_MEDIA_DEGRADE_20260919_END

    private func enableRemoteAudioTracks(_ tracks: [RTCAudioTrack], source: String, streamCount: Int) {
        let newTracks = tracks.filter { track in
            !remoteAudioTracks.contains { $0 === track }
        }
        for track in newTracks {
            track.isEnabled = true
            remoteAudioTracks.append(track)
        }
        if !tracks.isEmpty {
            rtcDebug("remote_audio_track_ready source=\(source) tracks=\(tracks.count) new=\(newTracks.count) streams=\(streamCount) route=\(audioRouteSummary())")
            emit(.remoteAudioTrackReady)
            startRemoteAudioReadinessProbe()
        }
    }

    func startRemoteAudioReadinessProbe() {
        guard mediaReadinessTask == nil,
              let context = currentContext,
              let peerConnection else { return }
        mediaReadinessGeneration &+= 1
        let generation = mediaReadinessGeneration
        let epoch = sessionEpoch
        let callID = context.callID
        mediaReadinessTask = Task { @MainActor [weak self] in
            defer {
                if self?.mediaReadinessGeneration == generation {
                    self?.mediaReadinessTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self,
                      self.mediaReadinessGeneration == generation,
                      self.sessionEpoch == epoch,
                      self.currentContext?.callID == callID,
                      self.peerConnection === peerConnection else { return }
                if self.isICEConnected, !self.remoteAudioTracks.isEmpty {
                    let sample = await self.inboundAudioRTPStats(peerConnection: peerConnection)
                    guard !Task.isCancelled,
                          self.mediaReadinessGeneration == generation,
                          self.sessionEpoch == epoch,
                          self.currentContext?.callID == callID,
                          self.peerConnection === peerConnection else { return }
                    let hasBaseline = self.lastInboundAudioBytes > 0 && self.lastInboundAudioPackets > 0
                    let grew = sample.bytes > self.lastInboundAudioBytes
                        && sample.packets > self.lastInboundAudioPackets
                    if hasBaseline, grew {
                        self.lastInboundAudioBytes = sample.bytes
                        self.lastInboundAudioPackets = sample.packets
                        self.rtcDebug("remote_audio_rtp_ready bytes=\(sample.bytes) packets=\(sample.packets)")
                        self.emit(.remoteAudioRTPReady)
                        return
                    }
                    if sample.bytes > 0, sample.packets > 0 {
                        self.lastInboundAudioBytes = sample.bytes
                        self.lastInboundAudioPackets = sample.packets
                    }
                }
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
        }
    }

    private func inboundAudioRTPStats(peerConnection: RTCPeerConnection) async -> (bytes: Int64, packets: Int64) {
        return await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                var bytes: Int64 = 0
                var packets: Int64 = 0
                for statistic in report.statistics.values {
                    guard statistic.type.lowercased() == "inbound-rtp" else { continue }
                    let kind = (statistic.values["kind"] as? String
                        ?? statistic.values["mediaType"] as? String
                        ?? "").lowercased()
                    guard kind == "audio" else { continue }
                    bytes += (statistic.values["bytesReceived"] as? NSNumber)?.int64Value ?? 0
                    packets += (statistic.values["packetsReceived"] as? NSNumber)?.int64Value ?? 0
                }
                continuation.resume(returning: (bytes, packets))
            }
        }
    }

    func closeCurrent(reason: String, sendBye: Bool, finishStream: Bool) async {
        guard !isClosingCurrentSession else { return }
        isClosingCurrentSession = true
        defer { isClosingCurrentSession = false }
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：在换代前确认音频会话所有权，避免把自身也误判为非拥有者
        let shouldReleaseAudioSession = ownedAudioSessionEpoch == sessionEpoch
        ownedAudioSessionEpoch = nil
        mediaStartStage = "closed"
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        sessionEpoch &+= 1
        recoveryGeneration &+= 1
        let hadContext = currentContext != nil
        signalPollTask?.cancel()
        recoveryTask?.cancel()
        credentialRefreshTask?.cancel()
        mediaReadinessGeneration &+= 1
        mediaReadinessTask?.cancel()
        localCandidateFlushTask?.cancel()
        qualityProbeTask?.cancel()
        signalPollTask = nil
        recoveryTask = nil
        credentialRefreshTask = nil
        mediaReadinessTask = nil
        localCandidateFlushTask = nil
        qualityProbeTask = nil
        if sendBye, hadContext {
            try? await postSignal(kind: .bye, data: ["reason": .string(reason)])
        }
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        remoteAudioTracks.removeAll()
        pendingRemoteCandidates.removeAll()
        remoteCandidateKeys.removeAll()
        pendingLocalCandidateSignals.removeAll(keepingCapacity: false)
        currentContext = nil
        signalState = RTCVideoSignalRuntimeState(rtcToken: "")
        signalOutbox = RTCVideoSignalOutbox()
        isFlushingSignalOutbox = false
        sequence = 0
        negotiationID = Self.makeNegotiationID()
        recoveryBudget = RTCVoiceRecoveryBudget()
        qualitySampleReducer = RTCQualitySampleReducer()
        qualitySampleSequence = 0
        isICEConnected = false
        hasConnected = false
        lastInboundAudioBytes = 0
        lastInboundAudioPackets = 0
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
        if shouldReleaseAudioSession {
            audioSession.isAudioEnabled = false
            try? audioSession.setActive(false)
        }
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        audioSession.unlockForConfiguration()
        // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始
        rtcDebug("closed reason=\(reason) sendBye=\(sendBye) releasedAudio=\(shouldReleaseAudioSession)")
        // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
        if finishStream {
            eventContinuation?.finish()
            eventContinuation = nil
        }
        currentDebugID = ""
    }

    private func audioRouteSummary() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { $0.portType.rawValue }.sorted().joined(separator: "|")
        let outputs = route.outputs.map { $0.portType.rawValue }.sorted().joined(separator: "|")
        return "in=\(inputs.isEmpty ? "none" : inputs) out=\(outputs.isEmpty ? "none" : outputs)"
    }

    func emit(_ event: RTCVoiceMediaEvent) {
        rtcDebug("event=\(event.rawValue) mediaState=\(event.mediaState.rawValue)")
        eventContinuation?.yield(event)
    }

    func rtcDebug(_ message: @autoclosure () -> String) {
        let value = message()
        let callID = currentDebugID.isEmpty ? "no-call" : currentDebugID
#if DEBUG
        NSLog("[JHT RTC][%@] %@", callID, value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(category: "VoiceMedia", media: "voice", callID: callID, message: value)
        }
    }

    static func shortDebugID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(4)) + "..." + String(trimmed.suffix(4))
    }

    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：只记录安全错误字段，不输出 userInfo/凭据
    private static func safeErrorSummary(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
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
    }
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束

    static func makeNegotiationID() -> String {
        "voice-neg-\(UUID().uuidString.lowercased())"
    }

    static func currentRFC3339Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func shortStableHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "missing" }
        var hash: UInt32 = 2_166_136_261
        for byte in trimmed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    static func safeErrorLabel(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let apiError = error as? IMAPIError {
            switch apiError {
            case let .missingContext(message):
                return "missing_context:\(message)"
            case let .badURL(message):
                return "bad_url:\(message)"
            case .unauthorized:
                return "unauthorized"
            case .forbidden:
                return "forbidden"
            case let .businessForbidden(code, _, _):
                return "business_forbidden:\(code)"
            case let .conflict(code, _):
                return "conflict:\(code)"
            case .server:
                return "server"
            case let .httpStatus(statusCode, _):
                return "http_status:\(statusCode)"
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
        return String(describing: type(of: error))
    }

    func rtcSdpType(from rawValue: String) -> RTCSdpType? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "offer":
            return .offer
        case "answer":
            return .answer
        default:
            return nil
        }
    }
}

extension WebRTCVoiceMediaClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let audioTracks = stream.audioTracks
        let audioTrackCount = audioTracks.count
        Task { @MainActor [weak self] in
            self?.rtcDebug("remote_stream_added audioTracks=\(audioTrackCount)")
            self?.enableRemoteAudioTracks(audioTracks, source: "stream", streamCount: 1)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let event: RTCVoiceMediaEvent?
        switch newState {
        case .checking:
            event = .iceChecking
        case .connected:
            event = .iceConnected
        case .completed:
            event = .iceCompleted
        case .disconnected:
            event = .iceDisconnected
        case .failed:
            event = .iceFailed
        case .closed:
            event = .closed
        default:
            event = nil
        }
        guard let event else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rtcDebug("ice_state event=\(event.rawValue)")
            switch event {
            case .iceConnected, .iceCompleted:
                self.markConnected()
            case .iceDisconnected:
                self.isICEConnected = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.scheduleRecovery(
                    graceSeconds: RTCVoiceRecoveryBudget.disconnectedGrace,
                    trigger: "ice_disconnected"
                )
            case .iceFailed:
                self.isICEConnected = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.scheduleRecovery(graceSeconds: 0, trigger: "ice_failed")
            default:
                break
            }
            self.emit(event == .iceFailed ? .iceDisconnected : event)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            await self?.flushPendingLocalCandidates(reason: "ice_complete")
            try? await self?.postSignal(kind: .iceComplete, data: RTCSignalPayloadCodec.iceCompleteData)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            await self?.postCandidate(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        let kind = rtpReceiver.track?.kind ?? "unknown"
        let streamCount = mediaStreams.count
        let audioTrack = rtpReceiver.track as? RTCAudioTrack
        Task { @MainActor [weak self] in
            self?.rtcDebug("remote_track_added kind=\(kind) streams=\(streamCount)")
            if let audioTrack {
                self?.enableRemoteAudioTracks([audioTrack], source: "receiver", streamCount: streamCount)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let event: RTCVoiceMediaEvent?
        switch newState {
        case .connected:
            event = .peerConnectionConnected
        case .disconnected:
            event = .iceDisconnected
        case .failed:
            event = .iceFailed
        case .closed:
            event = .closed
        default:
            event = nil
        }
        guard let event else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rtcDebug("pc_state event=\(event.rawValue)")
            switch event {
            case .peerConnectionConnected:
                self.markConnected()
            case .iceDisconnected:
                self.isICEConnected = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.scheduleRecovery(
                    graceSeconds: RTCVoiceRecoveryBudget.disconnectedGrace,
                    trigger: "peer_disconnected"
                )
            case .iceFailed:
                self.isICEConnected = false
                self.lastInboundAudioBytes = 0
                self.lastInboundAudioPackets = 0
                self.mediaReadinessGeneration &+= 1
                self.mediaReadinessTask?.cancel()
                self.mediaReadinessTask = nil
                self.scheduleRecovery(graceSeconds: 0, trigger: "peer_failed")
            default:
                break
            }
            self.emit(event == .iceFailed ? .iceDisconnected : event)
        }
    }
}
#else
@MainActor
final class WebRTCVoiceMediaClient: VoiceMediaClient {
    var isAvailable: Bool { false }

    func start(context: VoiceMediaSessionContext) async throws -> AsyncStream<RTCVoiceMediaEvent> {
        throw IMAPIError.server("当前 iOS 版本暂未接入真实语音媒体")
    }

    func setMuted(_ isMuted: Bool) async {}

    func setSpeakerEnabled(_ isEnabled: Bool) async {}

    // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始
    func reconcileAudioSessionAfterSystemEvent(speakerOn _: Bool) async throws {}
    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束

    func stop(reason: String) async {}
}
#endif

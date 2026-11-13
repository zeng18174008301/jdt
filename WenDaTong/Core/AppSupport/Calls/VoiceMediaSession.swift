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

typealias RTCSignalSender = @MainActor (_ envelope: RemoteRTCSignalEnvelope, _ rtcToken: String) async throws -> RemoteRTCSignalPostResult
typealias RTCSignalPoller = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> RemoteRTCSignalItemsData
typealias RTCSignalAcknowledger = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> Void
typealias RTCVoiceIceCredentialRefresher = @MainActor (_ rtcToken: String) async throws -> RemoteRTCIceCredentials

struct VoiceMediaSessionContext {
    let callID: String
    let roomID: String
    var rtcToken: String
    let direction: String
    let localUID: String
    let localDeviceID: String
    let localDeviceSource: String
    let peerUID: String
    let peerDeviceID: String
    let peerDeviceSource: String
    let mediaBaseURL: String
    var iceServers: [RemoteRTCIceServer]
    var iceCredentialExpiresAt: String
    var iceCredentialRefreshAfter: String
    var icePolicy: RTCIcePolicy = .legacy
    let postSignal: RTCSignalSender
    let pollSignals: RTCSignalPoller
    let acknowledgeSignals: RTCSignalAcknowledger
    let refreshIceCredentials: RTCVoiceIceCredentialRefresher

    var isCaller: Bool {
        let normalized = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("呼出")
            || normalized.contains("caller")
            || normalized.contains("outgoing")
            || normalized.contains("dial")
    }
}

struct RTCVoiceCredentialRefreshSnapshot: Sendable, Equatable {
    let sessionEpoch: Int
    let recoveryGeneration: Int
    let callID: String
    let roomID: String
    let rtcToken: String

    func matches(
        sessionEpoch: Int,
        recoveryGeneration: Int,
        callID: String,
        roomID: String,
        rtcToken: String
    ) -> Bool {
        self.sessionEpoch == sessionEpoch
            && self.recoveryGeneration == recoveryGeneration
            && self.callID == callID
            && self.roomID == roomID
            && self.rtcToken == rtcToken
    }
}

struct RTCVoiceRecoveryBudget: Sendable, Equatable {
    static let maximumAttempts = 2
    static let maximumWindow: TimeInterval = 15
    static let disconnectedGrace: TimeInterval = 2
    static let connectionAttemptTimeout: TimeInterval = 3

    private(set) var attempts = 0
    private(set) var startedAt: Date?

    mutating func startWindowIfNeeded(now: Date = Date()) {
        if startedAt == nil {
            startedAt = now
        }
    }

    mutating func claimAttempt(now: Date = Date()) -> Int? {
        startWindowIfNeeded(now: now)
        guard attempts < Self.maximumAttempts,
              let startedAt,
              now.timeIntervalSince(startedAt) < Self.maximumWindow else {
            return nil
        }
        attempts += 1
        return attempts
    }

    func remainingWindow(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return Self.maximumWindow }
        return max(0, Self.maximumWindow - now.timeIntervalSince(startedAt))
    }

    mutating func reset() {
        self = RTCVoiceRecoveryBudget()
    }

    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        attempt <= 1 ? 1 : 0
    }
}

enum RTCVoiceRecoveryDeadlineError: Error, Equatable {
    case exceeded
}

@MainActor
private final class RTCVoiceRecoveryDeadlineRace {
    private var continuation: CheckedContinuation<Void, Error>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var isResolved = false

    func install(
        continuation: CheckedContinuation<Void, Error>,
        operationTask: Task<Void, Never>,
        deadlineTask: Task<Void, Never>
    ) {
        guard !isResolved else {
            operationTask.cancel()
            deadlineTask.cancel()
            return
        }
        self.continuation = continuation
        self.operationTask = operationTask
        self.deadlineTask = deadlineTask
    }

    func resolve(_ result: Result<Void, Error>) {
        guard !isResolved else { return }
        isResolved = true
        let continuation = continuation
        let operationTask = operationTask
        let deadlineTask = deadlineTask
        self.continuation = nil
        self.operationTask = nil
        self.deadlineTask = nil
        operationTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(with: result)
    }
}

@MainActor
enum RTCVoiceRecoveryDeadline {
    static func run(
        timeout: TimeInterval,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        guard timeout > 0 else {
            throw RTCVoiceRecoveryDeadlineError.exceeded
        }
        let race = RTCVoiceRecoveryDeadlineRace()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operationTask = Task { @MainActor in
                    do {
                        try await operation()
                        race.resolve(.success(()))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutNanoseconds = UInt64(
                    min(timeout, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000
                )
                let deadlineTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        race.resolve(.failure(RTCVoiceRecoveryDeadlineError.exceeded))
                    } catch {
                        // The winning operation or parent cancellation owns resolution.
                    }
                }
                race.install(
                    continuation: continuation,
                    operationTask: operationTask,
                    deadlineTask: deadlineTask
                )
            }
        } onCancel: {
            Task { @MainActor in
                race.resolve(.failure(CancellationError()))
            }
        }
    }
}

enum RTCVoiceIceServerSet {
    static func hasUsableTurnRelay(_ servers: [RemoteRTCIceServer]) -> Bool {
        servers.contains { server in
            server.urls.contains { rawURL in
                let normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.hasPrefix("turn:") || normalized.hasPrefix("turns:")
            }
        }
    }

    static func relayCount(_ servers: [RemoteRTCIceServer]) -> Int {
        servers.reduce(into: 0) { count, server in
            if server.urls.contains(where: {
                let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.hasPrefix("turn:") || normalized.hasPrefix("turns:")
            }) {
                count += 1
            }
        }
    }
}

enum RTCSignalPayloadCodec {
    static let iceCompleteData: [String: JSONValue] = [:]

    static func iceRestartData(reason: String = "stable_token") -> [String: JSONValue] {
        ["reason": .string(reason)]
    }

    static func sessionDescriptionData(type: String, sdp: String) -> [String: JSONValue] {
        [
            "type": .string(type),
            "sdp": .string(sdp)
        ]
    }

    static func candidateData(_ candidates: [RemoteRTCIceCandidateSignalData]) -> [String: JSONValue] {
        let values = candidates.map { candidate in
            var object: [String: JSONValue] = [
                "candidate": .string(candidate.candidate)
            ]
            if let sdpMid = candidate.sdpMid {
                object["sdp_mid"] = .string(sdpMid)
            }
            if let sdpMLineIndex = candidate.sdpMLineIndex {
                object["sdp_mline_index"] = .int(sdpMLineIndex)
            }
            if let usernameFragment = candidate.usernameFragment {
                object["username_fragment"] = .string(usernameFragment)
            }
            return JSONValue.object(object)
        }
        return ["candidates": .array(values)]
    }

    static func sessionDescription(from data: [String: JSONValue]) throws -> RemoteRTCSessionDescriptionSignalData {
        try decode(RemoteRTCSessionDescriptionSignalData.self, from: data)
    }

    static func candidates(from data: [String: JSONValue]) throws -> [RemoteRTCIceCandidateSignalData] {
        try decode(RemoteRTCIceCandidatesSignalData.self, from: data).candidates
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: [String: JSONValue]) throws -> T {
        let encoded = try JSONEncoder().encode(data)
        return try JSONDecoder().decode(type, from: encoded)
    }
}

@MainActor
protocol VoiceMediaClient: AnyObject {
    var isAvailable: Bool { get }

    func start(context: VoiceMediaSessionContext) async throws -> AsyncStream<RTCVoiceMediaEvent>
    func setMuted(_ isMuted: Bool) async
    func setSpeakerEnabled(_ isEnabled: Bool) async
    // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始：系统音频路由/服务重建后，纯语音通话也恢复 WebRTC 音频会话
    func reconcileAudioSessionAfterSystemEvent(speakerOn: Bool) async throws
    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束
    func stop(reason: String) async
}

@MainActor
final class NoopVoiceMediaClient: VoiceMediaClient {
    var isAvailable: Bool { false }

    func start(context: VoiceMediaSessionContext) async throws -> AsyncStream<RTCVoiceMediaEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func setMuted(_ isMuted: Bool) async {}

    func setSpeakerEnabled(_ isEnabled: Bool) async {}

    // JHT_MOD_BEGIN RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改开始
    func reconcileAudioSessionAfterSystemEvent(speakerOn _: Bool) async throws {}
    // JHT_MOD_END RTC_VOICE_AUDIO_RECONCILE_20260914 - 修改结束

    func stop(reason: String) async {}
}

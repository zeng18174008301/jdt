import AVFoundation
import Foundation

#if canImport(CallKit)
@preconcurrency import CallKit
#endif

#if canImport(PushKit)
@preconcurrency import PushKit
#endif

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

typealias RTCSignalSender = @MainActor (_ envelope: RemoteRTCSignalEnvelope, _ rtcToken: String) async throws -> RemoteRTCSignalPostResult
typealias RTCSignalPoller = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> RemoteRTCSignalItemsData
typealias RTCSignalAcknowledger = @MainActor (_ cursor: String, _ rtcToken: String) async throws -> Void
typealias RTCVoiceIceCredentialRefresher = @MainActor (_ rtcToken: String) async throws -> RemoteRTCIceCredentials

actor RTCCallDiagnosticLogStore {
    static let shared = RTCCallDiagnosticLogStore()

    private static let maxLogBytes: UInt64 = 2_000_000
    private static let maxLineCharacters = 2_400

    private let fileManager: FileManager
    private let directoryURL: URL
    private let logURL: URL
    private let previousLogURL: URL
    private let timestampFormatter: ISO8601DateFormatter
    private var sequence: UInt64 = 0

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("RTCCallDiagnostics", isDirectory: true)
        self.directoryURL = directoryURL
        self.logURL = directoryURL.appendingPathComponent("rtc-call-diagnostics.log")
        self.previousLogURL = directoryURL.appendingPathComponent("rtc-call-diagnostics.previous.log")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = formatter
    }

    func append(category: String, media: String? = nil, callID: String? = nil, message: String, at date: Date = Date()) {
        do {
            try prepareDirectory()
            try rotateLogIfNeeded()
            ensureLogFileExists()
            sequence += 1
            let normalizedCategory = sanitizeField(category)
            let normalizedMedia = normalizeMedia(media)
            let normalizedCallID = sanitizeField(callID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            let callComponent = normalizedCallID.isEmpty ? "" : " call=\(normalizedCallID)"
            let line = "\(timestampFormatter.string(from: date)) seq=\(sequence) media=\(normalizedMedia) [\(normalizedCategory)]\(callComponent) \(sanitizeMessage(message))\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Diagnostics must never affect call behavior.
        }
    }

    func makeExportTextFile() throws -> URL {
        try prepareDirectory()
        ensureLogFileExists()
        let generatedAt = Date()
        let exportURL = fileManager.temporaryDirectory
            .appendingPathComponent("rtc-call-diagnostics-\(exportStamp(for: generatedAt)).txt")
        var contents = exportHeader(generatedAt: generatedAt)
        var hasLogContent = false
        if let previousLog = logText(from: previousLogURL), !previousLog.isEmpty {
            contents += "\n# Previous rotated log\n"
            contents += previousLog
            hasLogContent = true
        }
        if let currentLog = logText(from: logURL), !currentLog.isEmpty {
            contents += "\n# Current log\n"
            contents += currentLog
            hasLogContent = true
        }
        if !hasLogContent {
            contents += "\nNo RTC call diagnostic lines recorded yet.\n"
        }
        try Data(contents.utf8).write(to: exportURL, options: .atomic)
        return exportURL
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func ensureLogFileExists() {
        guard !fileManager.fileExists(atPath: logURL.path) else { return }
        fileManager.createFile(atPath: logURL.path, contents: nil)
    }

    private func rotateLogIfNeeded() throws {
        guard currentLogSize() >= Self.maxLogBytes else { return }
        if fileManager.fileExists(atPath: previousLogURL.path) {
            try? fileManager.removeItem(at: previousLogURL)
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.moveItem(at: logURL, to: previousLogURL)
        }
    }

    private func currentLogSize() -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func logText(from url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func exportHeader(generatedAt: Date) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? "问达通"
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        return """
        # \(displayName) RTC Call Diagnostics
        generated_at=\(timestampFormatter.string(from: generatedAt))
        bundle_id=\(bundleID)
        app_version=\(version)
        build=\(build)
        file_format=txt
        media_legend=voice:语音通话, video:视频通话, unknown:共享/系统链路
        note=Short identifiers and redacted diagnostic events only. RTC tokens are not written by this logger.

        """
    }

    private func exportStamp(for date: Date) -> String {
        timestampFormatter
            .string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func sanitizeField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeMedia(_ value: String?) -> String {
        let normalized = sanitizeField(value ?? "").lowercased()
        switch normalized {
        case "voice", "audio":
            return "voice"
        case "video":
            return "video"
        default:
            return "unknown"
        }
    }

    private func sanitizeMessage(_ message: String) -> String {
        var sanitized = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(
            of: "(?i)(authorization|bearer|token|rtcToken)[=: ]+[^\\s]+",
            with: "$1=<redacted>",
            options: .regularExpression
        )
        if sanitized.count > Self.maxLineCharacters {
            return String(sanitized.prefix(Self.maxLineCharacters)) + "...[truncated]"
        }
        return sanitized
    }
}

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

enum VoiceCallSystemEvent: Sendable, Equatable {
    case voipTokenUpdated(RemoteDeviceRegistration)
    case voipTokenInvalidated
    case voipPushPayload(RTCVoIPPushPayload)
    case voipPushReportFailed(RTCVoIPPushPayload)
    case voipPushContractViolation(RTCVoIPPushPayload)
    case answer(callID: String)
    case end(callID: String, reason: String)
    case mute(callID: String, isMuted: Bool)
    case audioSessionActivated
    case audioSessionDeactivated
    case providerReset
}

protocol VoiceCallSystemIntegrating: AnyObject, Sendable {
    var events: AsyncStream<VoiceCallSystemEvent> { get }

    func start()
    @discardableResult
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool
    func endCall(callID: String, reason: String)
    func setMuted(callID: String, isMuted: Bool)
    // WDT_IOS1_CALLKIT_ANSWER_20260921: in-app answers must also advance a presented system call.
    func answerPresentedCall(callID: String) async throws
    func hasPresentedCall(callID: String) -> Bool
    func clearPresentedCall(callID: String)
    func reportOutgoingCallStarted(callID: String, peerName: String, isVideo: Bool)
    func reportOutgoingCallConnected(callID: String)
}

extension VoiceCallSystemIntegrating {
    // WDT_IOS1_CALLKIT_ANSWER_20260921: integrations without CallKit need no system transaction.
    func answerPresentedCall(callID _: String) async throws {}
    func reportOutgoingCallStarted(callID _: String, peerName _: String, isVideo _: Bool) {}
    func reportOutgoingCallConnected(callID _: String) {}
}

final class NoopVoiceCallSystemIntegration: VoiceCallSystemIntegrating, @unchecked Sendable {
    let events: AsyncStream<VoiceCallSystemEvent>

    init() {
        events = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func start() {}
    @discardableResult
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool { false }
    func endCall(callID: String, reason: String) {}
    func setMuted(callID: String, isMuted: Bool) {}
    func hasPresentedCall(callID: String) -> Bool { false }
    func clearPresentedCall(callID: String) {}
}

enum IncomingCallAdmission: Equatable {
    case invalid
    case duplicate
    case busy
    case accept
}

enum IncomingCallAdmissionPolicy {
    static func resolve(
        callID rawCallID: String,
        isRinging: Bool,
        presentedCallIDs: Set<String>
    ) -> IncomingCallAdmission {
        let callID = rawCallID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRinging, !callID.isEmpty else { return .invalid }
        if presentedCallIDs.contains(callID) { return .duplicate }
        if !presentedCallIDs.isEmpty { return .busy }
        return .accept
    }
}

enum VoIPPushTransportAction: Equatable, Sendable {
    case reportIncomingCall
    case ignoreAndReconcile
}

enum VoIPPushTransportPolicy {
    static func action(for payload: RTCVoIPPushPayload) -> VoIPPushTransportAction {
        payload.isPushKitEligibleRinging ? .reportIncomingCall : .ignoreAndReconcile
    }
}

// Simulator lacks the system call UI host. Use the existing in-app call path there;
// keep CallKit and PushKit integration on physical devices.
#if canImport(CallKit) && canImport(PushKit) && !targetEnvironment(simulator)
final class CallKitPushVoiceCallManager: NSObject, VoiceCallSystemIntegrating, @unchecked Sendable {
    static let shared = CallKitPushVoiceCallManager()

    private let provider: CXProvider
    private var pushRegistry: PKPushRegistry?
    private let eventStream: AsyncStream<VoiceCallSystemEvent>
    private var eventContinuation: AsyncStream<VoiceCallSystemEvent>.Continuation?
    private var callIDsByUUID: [UUID: String] = [:]
    private var uuidsByCallID: [String: UUID] = [:]
    private var mediaByCallID: [String: String] = [:]
    private var presentedCallIDs: Set<String> = []
    private var didStart = false

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "问达通")
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        var continuation: AsyncStream<VoiceCallSystemEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
        super.init()
    }

    var events: AsyncStream<VoiceCallSystemEvent> {
        eventStream
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        callKitDebug("start")
        provider.setDelegate(self, queue: nil)
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
    }

    @discardableResult
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool {
        reportIncomingCall(payload, completion: nil)
    }

    func endCall(callID: String, reason: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        let uuid = uuid(for: normalizedCallID)
        let media = mediaLabel(forCallID: normalizedCallID)
        callKitDebug("end_call call=\(Self.shortDebugID(normalizedCallID)) reason=\(reason)", media: media)
        provider.reportCall(with: uuid, endedAt: Date(), reason: callEndedReason(for: reason))
        removeCallID(normalizedCallID, uuid: uuid)
    }

    func setMuted(callID: String, isMuted: Bool) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty,
              let uuid = uuidsByCallID[normalizedCallID] else { return }
        let transaction = CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: isMuted))
        CXCallController().request(transaction) { _ in }
    }

    // WDT_IOS1_CALLKIT_ANSWER_20260921_BEGIN: use the existing UUID; never create a second system call.
    func answerPresentedCall(callID: String) async throws {
        let normalized = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard presentedCallIDs.contains(normalized), let uuid = uuidsByCallID[normalized] else {
            throw CancellationError()
        }
        callKitDebug("in_app_answer_request call=\(Self.shortDebugID(normalized))")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CXCallController().request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    // WDT_IOS1_CALLKIT_ANSWER_20260921_END

    func hasPresentedCall(callID: String) -> Bool {
        presentedCallIDs.contains(callID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clearPresentedCall(callID: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        removeCallID(normalizedCallID, uuid: uuidsByCallID[normalizedCallID])
    }

    func reportOutgoingCallStarted(callID: String, peerName _: String, isVideo: Bool) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        let media = Self.mediaLabel(isVideo: isVideo)
        let uuid = uuid(for: normalizedCallID)
        presentedCallIDs.insert(normalizedCallID)
        mediaByCallID[normalizedCallID] = media
        let action = CXStartCallAction(
            call: uuid,
            handle: CXHandle(type: .generic, value: IOSNotificationPrivacyCopy.generic)
        )
        action.isVideo = isVideo
        CXCallController().request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                self?.callKitDebug("outgoing_start_failed call=\(Self.shortDebugID(normalizedCallID)) error=\(Self.callKitErrorSummary(error))", media: media)
                self?.removeCallID(normalizedCallID, uuid: uuid)
            }
        }
    }

    func reportOutgoingCallConnected(callID: String) {
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty, let uuid = uuidsByCallID[normalizedCallID] else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    @discardableResult
    private func reportIncomingCall(_ payload: RTCVoIPPushPayload, completion: (@Sendable (Error?) -> Void)?) -> Bool {
        let normalizedCallID = payload.callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let media = Self.mediaLabel(callType: payload.callType)
        switch IncomingCallAdmissionPolicy.resolve(
            callID: normalizedCallID,
            isRinging: payload.isRinging,
            presentedCallIDs: presentedCallIDs
        ) {
        case .invalid:
            completion?(nil)
            return false
        case .duplicate:
            callKitDebug("report_incoming_deduplicated call=\(Self.shortDebugID(normalizedCallID))", media: media)
            completion?(nil)
            return true
        case .busy:
            callKitDebug("report_incoming_busy call=\(Self.shortDebugID(normalizedCallID))", media: media)
            completion?(nil)
            return false
        case .accept:
            break
        }
        let uuid = uuid(for: normalizedCallID)
        callIDsByUUID[uuid] = normalizedCallID
        uuidsByCallID[normalizedCallID] = uuid
        mediaByCallID[normalizedCallID] = media
        presentedCallIDs.insert(normalizedCallID)
        callKitDebug("report_incoming_start call=\(Self.shortDebugID(normalizedCallID)) event=\(payload.event)", media: media)

        let update = CXCallUpdate()
        let privacyKind = IOSNotificationPrivacyCopy.authoritativeCallRequest(
            payloadType: payload.kind,
            eventType: payload.event,
            callType: payload.callType,
            callID: payload.callID
        )
        let notificationText = IOSNotificationPrivacyCopy.text(for: privacyKind)
        update.remoteHandle = CXHandle(type: .generic, value: notificationText)
        let isVideo = payload.callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video"
        update.localizedCallerName = notificationText
        update.hasVideo = isVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                self?.callKitDebug("report_incoming_failed call=\(Self.shortDebugID(normalizedCallID)) error=\(Self.callKitErrorSummary(error))", media: media)
                self?.removeCallID(normalizedCallID, uuid: uuid)
            } else {
                self?.callKitDebug("report_incoming_ok call=\(Self.shortDebugID(normalizedCallID))", media: media)
            }
            completion?(error)
        }
        return true
    }

    private func uuid(for callID: String) -> UUID {
        if let uuid = uuidsByCallID[callID] {
            return uuid
        }
        let uuid = RTCVoIPPushPayload.deterministicUUIDForCallKit(callID)
        uuidsByCallID[callID] = uuid
        callIDsByUUID[uuid] = callID
        return uuid
    }

    private func removeCallID(_ callID: String, uuid: UUID?) {
        presentedCallIDs.remove(callID)
        uuidsByCallID.removeValue(forKey: callID)
        mediaByCallID.removeValue(forKey: callID)
        if let uuid {
            callIDsByUUID.removeValue(forKey: uuid)
        }
    }

    private func callID(for uuid: UUID) -> String? {
        callIDsByUUID[uuid]
    }

    private func mediaLabel(forCallID callID: String) -> String? {
        mediaByCallID[callID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private func currentPresentedMediaLabel() -> String? {
        for callID in presentedCallIDs {
            if let media = mediaByCallID[callID] {
                return media
            }
        }
        return nil
    }

    private func callEndedReason(for rawReason: String) -> CXCallEndedReason {
        switch rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "timeout", "timed_out", "unanswered":
            return .unanswered
        case "answered_elsewhere":
            return .answeredElsewhere
        case "failed":
            return .failed
        default:
            return .remoteEnded
        }
    }

    private func yield(_ event: VoiceCallSystemEvent) {
        eventContinuation?.yield(event)
    }

    private func callKitDebug(_ message: @autoclosure () -> String, media: String? = nil) {
        let value = message()
        NSLog("[JHT RTC][CallKit] %@", value)
        Task {
            await RTCCallDiagnosticLogStore.shared.append(category: "CallKit", media: media, message: value)
        }
    }

    private static func mediaLabel(isVideo: Bool) -> String {
        isVideo ? "video" : "voice"
    }

    private static func mediaLabel(callType: String) -> String {
        callType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" ? "video" : "voice"
    }

    private static func shortDebugID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        let suffix = trimmed.suffix(8)
        return suffix.count == trimmed.count ? String(suffix) : "...\(suffix)"
    }

    private static func callKitErrorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}

private final class PushKitCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func complete() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}

extension CallKitPushVoiceCallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        callKitDebug("voip_token_updated")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jianhuitongqiyetest.app"
        let environment = IOSAPNsEnvironmentPolicy.resolve(
            infoValue: Bundle.main.object(forInfoDictionaryKey: "WXTAPNsEnvironment") as? String
        )
        let registration = RemoteDeviceRegistration.voip(
            token: pushCredentials.token.jhtHexString,
            bundleID: bundleID,
            environment: environment
        )
        yield(.voipTokenUpdated(registration))
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        callKitDebug("voip_token_invalidated")
        yield(.voipTokenInvalidated)
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let completionBox = PushKitCompletionBox(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            completionBox.complete()
        }
        guard type == .voIP else {
            callKitDebug("push_ignored reason=non_voip")
            completionBox.complete()
            return
        }
        guard let rtcPayload = RTCVoIPPushPayload(payload.dictionaryPayload) else {
            callKitDebug("push_ignored reason=payload_parse_failed")
            completionBox.complete()
            return
        }
        let media = Self.mediaLabel(callType: rtcPayload.callType)
        callKitDebug("push_received event=\(rtcPayload.event) call=\(Self.shortDebugID(rtcPayload.callID))", media: media)

        guard VoIPPushTransportPolicy.action(for: rtcPayload) == .reportIncomingCall else {
            callKitDebug("push_contract_violation event=\(rtcPayload.event) call=\(Self.shortDebugID(rtcPayload.callID))", media: media)
            yield(.voipPushContractViolation(rtcPayload))
            completionBox.complete()
            return
        }

        let admission = IncomingCallAdmissionPolicy.resolve(
            callID: rtcPayload.callID,
            isRinging: rtcPayload.isRinging,
            presentedCallIDs: presentedCallIDs
        )
        switch admission {
        case .invalid:
            callKitDebug("push_ignored reason=invalid_ringing", media: media)
            completionBox.complete()
        case .duplicate:
            callKitDebug("push_deduplicated call=\(Self.shortDebugID(rtcPayload.callID))", media: media)
            yield(.voipPushPayload(rtcPayload))
            completionBox.complete()
        case .busy, .accept:
            if admission == .busy {
                callKitDebug("push_busy_report_attempt call=\(Self.shortDebugID(rtcPayload.callID))", media: media)
            }
            reportIncomingCall(rtcPayload) { [weak self] error in
                if error == nil {
                    self?.yield(.voipPushPayload(rtcPayload))
                } else {
                    self?.yield(.voipPushReportFailed(rtcPayload))
                }
                completionBox.complete()
            }
        }
    }
}

extension CallKitPushVoiceCallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        callKitDebug("provider_reset")
        callIDsByUUID.removeAll()
        uuidsByCallID.removeAll()
        mediaByCallID.removeAll()
        presentedCallIDs.removeAll()
        yield(.providerReset)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        if let callID = callID(for: action.callUUID) {
            callKitDebug("action_start call=\(Self.shortDebugID(callID))", media: mediaLabel(forCallID: callID))
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let callID = callID(for: action.callUUID) {
            callKitDebug("action_answer call=\(Self.shortDebugID(callID))", media: mediaLabel(forCallID: callID))
            yield(.answer(callID: callID))
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let callID = callID(for: action.callUUID) {
            callKitDebug("action_end call=\(Self.shortDebugID(callID))", media: mediaLabel(forCallID: callID))
            yield(.end(callID: callID, reason: "callkit_end"))
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let callID = callID(for: action.callUUID) {
            callKitDebug("action_mute call=\(Self.shortDebugID(callID)) muted=\(action.isMuted)", media: mediaLabel(forCallID: callID))
            yield(.mute(callID: callID, isMuted: action.isMuted))
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        callKitDebug("audio_session_did_activate", media: currentPresentedMediaLabel())
        #if canImport(WebRTC)
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.audioSessionDidActivate(audioSession)
        rtcAudioSession.isAudioEnabled = true
        #endif
        yield(.audioSessionActivated)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        callKitDebug("audio_session_did_deactivate", media: currentPresentedMediaLabel())
        #if canImport(WebRTC)
        let rtcAudioSession = RTCAudioSession.sharedInstance()
        rtcAudioSession.audioSessionDidDeactivate(audioSession)
        rtcAudioSession.isAudioEnabled = false
        #endif
        yield(.audioSessionDeactivated)
    }
}

private extension Data {
    var jhtHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#else
final class CallKitPushVoiceCallManager: VoiceCallSystemIntegrating, @unchecked Sendable {
    static let shared = CallKitPushVoiceCallManager()

    let events: AsyncStream<VoiceCallSystemEvent>

    init() {
        events = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func start() {}
    @discardableResult
    func reportIncomingCall(_ payload: RTCVoIPPushPayload) -> Bool { false }
    func endCall(callID: String, reason: String) {}
    func setMuted(callID: String, isMuted: Bool) {}
    func hasPresentedCall(callID: String) -> Bool { false }
    func clearPresentedCall(callID: String) {}
}
#endif

#if canImport(WebRTC)
@MainActor
enum WebRTCRuntime {
    static let isReady: Bool = RTCInitializeSSL()
}

@MainActor
final class WebRTCVoiceMediaClient: NSObject, VoiceMediaClient {
    private let factory: RTCPeerConnectionFactory
    private var currentContext: VoiceMediaSessionContext?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTracks: [RTCAudioTrack] = []
    private var signalPollTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var credentialRefreshTask: Task<Void, Never>?
    private var mediaReadinessTask: Task<Void, Never>?
    private var mediaReadinessGeneration = 0
    private var eventContinuation: AsyncStream<RTCVoiceMediaEvent>.Continuation?
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var remoteCandidateKeys: Set<String> = []
    private var signalState = RTCVideoSignalRuntimeState(rtcToken: "")
    private var signalOutbox = RTCVideoSignalOutbox()
    private var pendingLocalCandidateSignals: [RemoteRTCIceCandidateSignalData] = []
    private var localCandidateFlushTask: Task<Void, Never>?
    private var isFlushingSignalOutbox = false
    private var currentDebugID: String = ""
    private var sessionEpoch = 0
    private var recoveryGeneration = 0
    private var recoveryBudget = RTCVoiceRecoveryBudget()
    private var isICEConnected = false
    private var hasConnected = false
    private var lastInboundAudioBytes: Int64 = 0
    private var lastInboundAudioPackets: Int64 = 0
    private var qualityProbeTask: Task<Void, Never>?
    private var qualitySampleReducer = RTCQualitySampleReducer()
    private var qualitySampleSequence: Int64 = 0
    private var isClosingCurrentSession = false
    // JHT_MOD_BEGIN IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改开始：跟踪本实例音频会话所有权和启动阶段，便于接听失败定位
    private var ownedAudioSessionEpoch: Int?
    // WDT_IOS1_AUDIO_ROUTE_20260921: preserve receiver/speaker intent across recovery.
    private var speakerEnabled = true
    private var mediaStartStage = "idle"
    // JHT_MOD_END IOS_RTC_ANSWER_MEDIA_FAILURE_20260917 - 修改结束
    private var sequence = 0
    private var negotiationID = WebRTCVoiceMediaClient.makeNegotiationID()
    private static let localCandidateBatchDelayNanoseconds: UInt64 = 25_000_000
    private static let localCandidateBatchMaxCount = 6

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

    private func makeIceServers(_ servers: [RemoteRTCIceServer]) -> [RTCIceServer] {
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

    private func startRemoteAudioReadinessProbe() {
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

#if DEBUG
    private func startVoiceQualityProbe() {
        guard qualityProbeTask == nil,
              let context = currentContext,
              let peerConnection else { return }
        let epoch = sessionEpoch
        let callID = context.callID
        qualityProbeTask = Task { @MainActor [weak self] in
            defer {
                if self?.sessionEpoch == epoch,
                   self?.currentContext?.callID == callID {
                    self?.qualityProbeTask = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self,
                      self.sessionEpoch == epoch,
                      self.currentContext?.callID == callID,
                      self.peerConnection === peerConnection,
                      self.hasConnected,
                      self.isICEConnected else { return }
                let records = await self.qualityStatRecords(for: peerConnection)
                self.qualitySampleSequence += 1
                guard let sample = self.qualitySampleReducer.reduce(
                    records: records,
                    sampledAt: Date(),
                    sampleSeq: self.qualitySampleSequence
                ) else { continue }
                self.rtcDebug(
                    "voice_quality issue=media_degrade_or_long_call_end route=\(sample.connectionRoute) proto=\(sample.candidateProtocol) rtt_ms=\(Self.qualityMetric(sample.rttMS)) jitter_ms=\(Self.qualityMetric(sample.jitterMS)) loss_pct=\(Self.qualityMetric(sample.packetLossPct)) conceal_pct=\(Self.qualityMetric(sample.audioConcealmentPct)) in_kbps=\(Self.qualityMetric(sample.inboundBitrateKbps)) out_kbps=\(Self.qualityMetric(sample.outboundBitrateKbps))"
                )
            }
        }
    }

    private func qualityStatRecords(for connection: RTCPeerConnection) async -> [RTCQualityStatRecord] {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                continuation.resume(returning: report.statistics.values.map { statistic in
                    let values = statistic.values
                    func string(_ key: String) -> String? {
                        values[key] as? String
                    }
                    func double(_ key: String) -> Double? {
                        (values[key] as? NSNumber)?.doubleValue
                    }
                    func int64(_ key: String) -> Int64? {
                        guard let value = (values[key] as? NSNumber)?.doubleValue,
                              value.isFinite, value.rounded(.towardZero) == value,
                              value >= 0, value <= 9_007_199_254_740_991 else { return nil }
                        return Int64(value)
                    }
                    func bool(_ key: String) -> Bool? {
                        (values[key] as? NSNumber)?.boolValue
                    }
                    func identifier(_ key: String) -> String? {
                        if let value = values[key] as? String { return value }
                        if let value = values[key] as? NSNumber { return value.stringValue }
                        return nil
                    }
                    return RTCQualityStatRecord(
                        id: statistic.id,
                        type: statistic.type,
                        timestampUS: statistic.timestamp_us,
                        selectedCandidatePairID: string("selectedCandidatePairId"),
                        localCandidateID: string("localCandidateId"),
                        remoteCandidateID: string("remoteCandidateId"),
                        candidateType: string("candidateType"),
                        protocolName: string("protocol"),
                        relayProtocol: string("relayProtocol"),
                        candidateURL: string("url"),
                        state: string("state"),
                        selected: bool("selected"),
                        nominated: bool("nominated"),
                        currentRoundTripTimeSeconds: double("currentRoundTripTime"),
                        availableOutgoingBitrateBPS: double("availableOutgoingBitrate"),
                        jitterSeconds: double("jitter"),
                        packetsLost: int64("packetsLost"),
                        packetsReceived: int64("packetsReceived"),
                        bytesReceived: int64("bytesReceived"),
                        bytesSent: int64("bytesSent"),
                        framesPerSecond: double("framesPerSecond"),
                        framesDropped: int64("framesDropped"),
                        concealedSamples: int64("concealedSamples"),
                        totalSamplesReceived: int64("totalSamplesReceived"),
                        freezeCount: int64("freezeCount"),
                        kind: string("kind"),
                        mediaType: string("mediaType"),
                        codecID: string("codecId"),
                        mimeType: string("mimeType"),
                        ssrc: identifier("ssrc"),
                        framesEncoded: int64("framesEncoded"),
                        framesSent: int64("framesSent"),
                        framesReceived: int64("framesReceived"),
                        framesDecoded: int64("framesDecoded")
                    )
                })
            }
        }
    }

    private static func qualityMetric(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f", value)
    }
#endif

    private func startSignalPolling(context: VoiceMediaSessionContext) {
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

    private func createAndSendOffer(iceRestart: Bool) async throws {
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

    private func postCandidate(_ candidate: RTCIceCandidate) async {
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

    private func flushPendingLocalCandidates(
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

    private func postSignal(kind: RemoteRTCSignalKind, data: [String: JSONValue]) async throws {
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

    private func scheduleCredentialRefresh(refreshAfter: String, expiresAt: String) {
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

    private func scheduleRecovery(graceSeconds: TimeInterval, trigger: String) {
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

    private func markConnected() {
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

    private func closeCurrent(reason: String, sendBye: Bool, finishStream: Bool) async {
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

    private func emit(_ event: RTCVoiceMediaEvent) {
        rtcDebug("event=\(event.rawValue) mediaState=\(event.mediaState.rawValue)")
        eventContinuation?.yield(event)
    }

    private func rtcDebug(_ message: @autoclosure () -> String) {
        let value = message()
        let callID = currentDebugID.isEmpty ? "no-call" : currentDebugID
#if DEBUG
        NSLog("[JHT RTC][%@] %@", callID, value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(category: "VoiceMedia", media: "voice", callID: callID, message: value)
        }
    }

    private static func shortDebugID(_ value: String) -> String {
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

    private static func makeNegotiationID() -> String {
        "voice-neg-\(UUID().uuidString.lowercased())"
    }

    private static func currentRFC3339Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func shortStableHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "missing" }
        var hash: UInt32 = 2_166_136_261
        for byte in trimmed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    private static func safeErrorLabel(_ error: Error) -> String {
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

    private func rtcSdpType(from rawValue: String) -> RTCSdpType? {
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

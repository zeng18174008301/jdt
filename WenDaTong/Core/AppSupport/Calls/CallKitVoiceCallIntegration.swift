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

// WDT_IOS1_CALLKIT_CN_POLICY_20260923_BEGIN: compile the system call UI only behind an explicit build flag.
#if WDT_ENABLE_CALLKIT && canImport(CallKit) && canImport(PushKit) && !targetEnvironment(simulator)
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
// WDT_IOS1_CALLKIT_CN_POLICY_20260923_END

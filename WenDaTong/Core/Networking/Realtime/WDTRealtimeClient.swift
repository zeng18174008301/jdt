import CryptoKit // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
import Foundation
import Network

enum RealtimeActiveTransportKind {
    case webSocket
    case quic
}

@MainActor
final class RealtimeClient: RealtimeTransporting {
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)?
    var canReconnect: (@MainActor () -> Bool)?
    var onConnectionUnavailable: (@MainActor () -> Void)?
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnectAttempt: (@MainActor () -> Void)?
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)? { didSet { onSerialEnvelope = nil } } // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
    var onSerialEnvelope: (@MainActor (RealtimeEnvelope, RealtimeEnvelopeDiagnosticObservation?, RealtimeDeliveryContext) async -> Void)? // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
    typealias IncomingAdmission = @MainActor () -> RealtimeConnectionDiagnostic.Handling?
    var captureIncomingAdmission: (@MainActor () -> IncomingAdmission)?
    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
    var onReconnectScheduled: (@MainActor (TimeInterval) -> Void)?
    var onQUICFallbackToWebSocket: (@MainActor (Error) -> Void)?
    var onRouteFailure: (@MainActor (Error) -> Void)?
    var diagnosticScopeProvider: (@MainActor () -> UInt64?)?
    var onDiagnostic: (@MainActor (RealtimeConnectionDiagnostic, UInt64?) -> Void)?
    private var diagnosticScopeEpoch: UInt64?
    private var diagnosticStartedAt: UInt64?
    var diagnosticRequests = RealtimeDiagnosticRequestIndex()
    private(set) var currentEnvelopeDiagnostic: RealtimeEnvelopeDiagnosticObservation?

    func recordAdmissionDiagnostic(_ result: RealtimeConnectionDiagnostic.Result) {
        recordDiagnostic(.admission, result: result, elapsedMS: 0)
    }

    func recordDiagnostic(
        _ stage: RealtimeConnectionDiagnostic.Stage,
        result: RealtimeConnectionDiagnostic.Result,
        elapsedMS: UInt64? = nil
    ) {
        let event = makeDiagnostic(stage, result: result, elapsedMS: elapsedMS)
        let scopeEpoch = stage == .admission ? diagnosticScopeProvider?() : diagnosticScopeEpoch
        publishDiagnostic(event, scopeEpoch: scopeEpoch)
    }

    private func makeDiagnostic(
        _ stage: RealtimeConnectionDiagnostic.Stage,
        result: RealtimeConnectionDiagnostic.Result,
        elapsedMS: UInt64? = nil
    ) -> RealtimeConnectionDiagnostic {
        let now = monotonicClock.nowNanoseconds()
        let start = diagnosticStartedAt ?? now
        var event = RealtimeConnectionDiagnostic(
            generation: connectionGeneration, stage: stage, result: result,
            transport: activeTransportKind.map { $0 == .webSocket ? .webSocket : .quic } ?? .none,
            elapsedMS: elapsedMS ?? (now >= start ? (now - start) / 1_000_000 : 0)
        )
        let scopeEpoch = stage == .admission ? diagnosticScopeProvider?() : diagnosticScopeEpoch
        if let scopeEpoch, let current = diagnosticScopeProvider?() {
            event.scopeMatch = scopeEpoch == current ? .current : .stale
        }
        return event
    }

    private func finishDiagnostic(_ original: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        var event = original
        event.stateAfter = connectionState
        event.generationAfter = connectionGeneration
        if let scopeEpoch, let current = diagnosticScopeProvider?() {
            event.scopeAfter = scopeEpoch == current ? .current : .stale
        }
        publishDiagnostic(event, scopeEpoch: scopeEpoch)
    }

    private func publishDiagnostic(_ event: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        SyncFailureDiagnostic.persistConnection(event)
        onDiagnostic?(event, scopeEpoch)
    }

    var socket: RealtimeWebSocketTasking?
    var quicConnection: RealtimeQUICConnectioning?
    var quicConnectTask: Task<Void, Never>?
    var quicConnectCancellation: (@Sendable () -> Void)?
    var receiveTask: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?
    var acknowledgementDeadlineTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var reconnectAttempt = 0
    var lastSocketFailureLog: (signature: String, uptime: TimeInterval)?
    var suppressedSocketFailureLogs = 0
    var connectedSinceUptime: TimeInterval?
    var subscriptionFramesSent = 0
    var awaitingPong = false
    var missedPongCount = 0
    private var lastNetworkPathStatus: RealtimeNetworkPathStatus?
    private let subscriptionSendInterval: UInt64 = 50_000_000
    var subscriptionSendTask: Task<Void, Never>?
    var pendingSubscriptions: ArraySlice<(key: String, payload: [String: String])> = []
    var pendingSubscriptionKeys: Set<String> = []
    var subscribedChannels: Set<String> = []
    var activeTransportKind: RealtimeActiveTransportKind?
    private(set) var activeRequest: RealtimeConnectionRequest?
    private var activeToken: String?
    var activeLegID: UInt64 = 0
    var activeConnectRequestID: String?
    var generationDeadlineNanoseconds: UInt64?
    var didFallbackToWebSocket = false
    let transport: RealtimeWebSocketTransporting
    let quicTransport: RealtimeQUICTransporting
    private let quicConfiguration: RealtimeQUICConfiguration
    private let wireCodec: any WireCodec
    let heartbeatIntervalNanoseconds: UInt64
    let acknowledgementTimeoutNanoseconds: UInt64
    private let generationTimeoutNanoseconds: UInt64 = 8_000_000_000
    let maximumMissedPongs: Int
    let reconnectCaps: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
    let reconnectDelayScale: Double
    let reconnectJitterProvider: @MainActor () -> Double
    private let requestIDProvider: @MainActor (String) -> String
    let monotonicClock: any RealtimeMonotonicClock
    private let networkMonitor: RealtimeNetworkMonitoring?
    private let realtimeBatchCapabilityEnabled: Bool
	private let continuity: IMRuntimeWebSocketContinuity
	private let continuityOwner = UUID().uuidString

    init(
        transport: RealtimeWebSocketTransporting = URLSessionRealtimeTransport(),
        quicTransport: RealtimeQUICTransporting = NWRealtimeQUICTransport(),
        quicConfiguration: RealtimeQUICConfiguration = RealtimeQUICConfiguration.load(),
        wireCodec: any WireCodec = JSONWireCodec(),
        heartbeatIntervalNanoseconds: UInt64 = 25_000_000_000,
        acknowledgementTimeoutNanoseconds: UInt64 = 5_000_000_000,
        maximumMissedPongs: Int = 2,
        reconnectDelayScale: Double = 1,
        reconnectJitterProvider: @escaping @MainActor () -> Double = { Double.random(in: 0..<1) },
        requestIDProvider: @escaping @MainActor (String) -> String = { type in
            "\(type)-\(UUID().uuidString)"
        },
        monotonicClock: any RealtimeMonotonicClock = SystemRealtimeMonotonicClock(),
        networkMonitorFactory: (() -> RealtimeNetworkMonitoring?)? = { NWPathRealtimeNetworkMonitor() },
		realtimeBatchCapabilityEnabled: Bool = false,
		continuity: IMRuntimeWebSocketContinuity = .shared
    ) {
        self.transport = transport
        self.quicTransport = quicTransport
        self.quicConfiguration = quicConfiguration
        self.wireCodec = wireCodec
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
        self.acknowledgementTimeoutNanoseconds = min(
            acknowledgementTimeoutNanoseconds,
            5_000_000_000
        )
        self.maximumMissedPongs = max(1, maximumMissedPongs)
        self.reconnectDelayScale = max(0, reconnectDelayScale)
        self.reconnectJitterProvider = reconnectJitterProvider
        self.requestIDProvider = requestIDProvider
		self.monotonicClock = monotonicClock
		self.continuity = continuity
        self.networkMonitor = networkMonitorFactory?()
        self.realtimeBatchCapabilityEnabled = realtimeBatchCapabilityEnabled
        self.networkMonitor?.start { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathStatus(status)
            }
        }
    }

    deinit {
        networkMonitor?.cancel()
		continuity.release(continuityOwner)
    }

    private(set) var connectionGeneration: UInt64 = 0

    private(set) var connectionState: RealtimeConnectionState = .idle {
        didSet {
            let wasConnected = oldValue == .connected
            let isNowConnected = connectionState == .connected
            guard wasConnected != isNowConnected else { return }
            onConnectionStateChanged?(isNowConnected)
        }
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    func start(url: URL, token: String) {
        start(request: RealtimeConnectionRequest(url: url, token: token))
    }

    func disconnect(shouldReconnect: Bool) {
        let diagnostic = makeDiagnostic(.socket, result: .stopRequested)
        let scopeEpoch = diagnosticScopeEpoch
        defer { finishDiagnostic(diagnostic, scopeEpoch: scopeEpoch) }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration &+= 1
        stopActiveLeg()
        activeRequest = nil
        activeToken = nil
		didFallbackToWebSocket = false
		if !shouldReconnect { continuity.release(continuityOwner) }
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String) {
        subscribe(channelID: channelID, channelType: channelType, tenantID: tenantID, imUID: imUID, deviceID: deviceID, priority: false)
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String, priority: Bool) {
        guard connectionState == .connected else { return }
        let trimmedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChannelID.isEmpty, !trimmedChannelType.isEmpty else { return }
        let key = "\(trimmedChannelType)|\(trimmedChannelID)"
        guard !subscribedChannels.contains(key) else { return }
        if !pendingSubscriptionKeys.insert(key).inserted {
            guard priority, let index = pendingSubscriptions.firstIndex(where: { $0.key == key }) else { return }
            let subscription = pendingSubscriptions.remove(at: index)
            pendingSubscriptions.insert(subscription, at: pendingSubscriptions.startIndex)
            return
        }
        let payload = [
            "tenant_id": tenantID,
            "im_uid": imUID,
            "device_id": deviceID,
            "channel_id": trimmedChannelID,
            "channel_type": trimmedChannelType
        ]
        if priority {
            pendingSubscriptions.insert((key, payload), at: pendingSubscriptions.startIndex)
        } else {
            pendingSubscriptions.append((key, payload))
        }
        guard subscriptionSendTask == nil else { return }
        sendNextSubscription()
        subscriptionSendTask = Task { @MainActor [weak self] in
            while let interval = self?.subscriptionSendInterval {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                if !self.sendNextSubscription() {
                    self.subscriptionSendTask = nil
                    return
                }
            }
        }
    }

    @discardableResult
    private func sendNextSubscription() -> Bool {
        while let subscription = pendingSubscriptions.popFirst() {
            pendingSubscriptionKeys.remove(subscription.key)
            guard !subscribedChannels.contains(subscription.key) else { continue }
            subscriptionFramesSent += 1
            sendPacket(type: "subscribe_channel", payload: subscription.payload)
            return true
        }
        pendingSubscriptions = []
        return false
    }

    func startFromProvider() {
        guard canReconnect?() == true else {
            recordAdmissionDiagnostic(.reconnectNotAllowed)
            transition(to: .idle)
            return
        }
        guard let request = connectionRequestProvider?() else {
            recordAdmissionDiagnostic(.routeUnavailable)
            transition(to: .idle)
            onConnectionUnavailable?()
            return
        }
        let previousGeneration = connectionGeneration
        start(request: request)
        if connectionGeneration != previousGeneration {
            onReconnectAttempt?()
        }
    }

    func start(request: RealtimeConnectionRequest) {
        let request = sanitizedConnectionRequest(request)
        guard !request.token.isEmpty else {
            recordAdmissionDiagnostic(.missingSession)
            return
        }
        guard continuity.acquire(continuityOwner) else {
            recordAdmissionDiagnostic(.ownerBusy)
            return
        }
        if [.dialing, .awaitingAck, .connected].contains(connectionState),
           activeToken == request.token {
            recordAdmissionDiagnostic(.alreadyActive)
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        stopActiveLeg()
        connectionGeneration &+= 1
        // Ownership belongs to the admitted generation, not the scope at callback time.
        diagnosticScopeEpoch = diagnosticScopeProvider?()
        diagnosticStartedAt = monotonicClock.nowNanoseconds()
        generationDeadlineNanoseconds = addingWithoutOverflow(
            generationTimeoutNanoseconds,
            to: monotonicClock.nowNanoseconds()
        )
        activeLegID = 0
        activeRequest = request
        activeToken = request.token
        didFallbackToWebSocket = false
        subscribedChannels.removeAll()

        let generation = connectionGeneration
        let discoveryQUICRequest = quicConfiguration.isEnabled ? request.quicRequest : nil
        if let quicRequest = discoveryQUICRequest ?? quicConfiguration.connectionRequest(token: request.token) {
            startQUIC(request: sanitizedQUICRequest(quicRequest, token: request.token), generation: generation)
        } else {
            startWebSocket(request: request, generation: generation)
        }
    }

    func handleActiveLegFailure(
        _ error: Error,
        retryAfter: TimeInterval?,
        generation: UInt64,
        legID: UInt64,
        kind: RealtimeActiveTransportKind,
        permitsQUICFallback: Bool = true
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: kind) else { return }
        let diagnostic = makeDiagnostic(.socket, result: .socketFailure(error))
        let scopeEpoch = diagnosticScopeEpoch
        defer { finishDiagnostic(diagnostic, scopeEpoch: scopeEpoch) }
        if kind == .quic,
           connectionState != .connected,
           !didFallbackToWebSocket,
           permitsQUICFallback,
           hasRemainingGenerationBudget(generation: generation) {
            fallbackToWebSocketAfterQUICFailure(error, generation: generation, legID: legID)
            return
        }

        let retryAfterFloor = retryAfterFloor(error: error, transportValue: retryAfter)
        logSocketFailure(error, kind: kind)
		onRouteFailure?(error)
        connectionGeneration &+= 1
        stopActiveLeg()
        guard canReconnect?() == true else { return }
        onDisconnected?()
        scheduleReconnect(retryAfterFloor: retryAfterFloor)
    }

    func connectPayload(token: String) -> [String: Any] {
        var payload: [String: Any] = ["token": token]
        if realtimeBatchCapabilityEnabled, activeTransportKind == .webSocket {
            payload["capabilities"] = ["batch"]
        }
        return payload
    }

	private func realtimeEnvelopeDedupeKey(_ envelope: RealtimeEnvelope) -> String? {
		let normalizedType = envelope.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let canonicalPayload: [String: JSONValue]
		switch normalizedType {
		case "message", "message_push", "send_ack":
			canonicalPayload = envelope.payload["message"]?.objectValue ?? envelope.payload
			let contentType = firstNonemptyValue(canonicalPayload, keys: ["content_type"])
				?? firstNonemptyValue(canonicalPayload["payload"]?.objectValue ?? [:], keys: ["content_type"])
			// RTC records are immutable authorities. Even malformed replays must reach
			// the store so payload/identity conflicts can open a recovery gap. The
			// store also owns exact-repeat unread and acknowledgement idempotency.
			if contentType?.lowercased() == "rtc_call_record" { return nil }
			if let id = firstNonemptyValue(canonicalPayload, keys: ["message_id", "id"]) {
				return "message|\(id)"
			}
		case "conversation_read":
			canonicalPayload = envelope.payload["read_watermark"]?.objectValue ?? envelope.payload
			guard let eventID = firstNonemptyValue(canonicalPayload, keys: ["event_id", "eventId"]) else {
				return nil
			}
			return "conversation_read|\(eventID)"
		case "message_receipt":
			canonicalPayload = envelope.payload["receipt"]?.objectValue ?? envelope.payload
			let fields = ["message_id", "receipt_type", "im_uid", "device_id", "channel_seq", "created_at"]
				.compactMap { canonicalPayload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if !fields.isEmpty { return "message_receipt|" + fields.joined(separator: "|") }
		case "message_extra":
			canonicalPayload = envelope.payload["extra"]?.objectValue ?? envelope.payload
			let fields = ["message_id", "version", "operator_uid", "extra_type", "emoji", "action", "created_at"]
				.compactMap { canonicalPayload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if !fields.isEmpty { return "message_extra|" + fields.joined(separator: "|") }
		default:
			guard let eventID = firstNonemptyValue(envelope.payload, keys: ["event_id"]) else { return nil }
			return "\(normalizedType)|\(eventID)"
		}
		let object = canonicalPayload.mapValues(\.anyValue)
		guard JSONSerialization.isValidJSONObject(object),
		      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
		let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		return "\(normalizedType)|sha256:\(digest)"
	}

	private func firstNonemptyValue(_ payload: [String: JSONValue], keys: [String]) -> String? {
		for key in keys {
			if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
				return value
			}
		}
		return nil
	}

    func sendConnectOverWebSocket(
        token: String,
        requestID: String,
        socket: RealtimeWebSocketTasking,
        generation: UInt64,
        legID: UInt64
    ) -> Bool {
        guard let text = packetText(
            type: "connect",
            requestID: requestID,
            payload: connectPayload(token: token)
        ) else {
            handleWebSocketFailure(
                RealtimeClientError.connectFrameEncodingFailed,
                socket: socket,
                generation: generation,
                legID: legID
            )
            return false
        }
        socket.send(.string(text)) { [weak self, weak socket] error in
            guard let error, let socket else { return }
            Task { @MainActor [weak self] in
                self?.handleWebSocketFailure(error, socket: socket, generation: generation, legID: legID)
            }
        }
        diagnosticRequests.record(requestID, operation: .connect)
        DebugConsoleDiagnostics.trace("[JHT Realtime] connect_frame_sent transport=websocket")
        return true
    }

    func sendPacket(type: String, payload: [String: Any]) {
        let generation = connectionGeneration
        let legID = activeLegID
        let requestID = nextRequestID(type: type)
        switch activeTransportKind {
        case .webSocket:
            guard let socket,
                  let text = packetText(type: type, requestID: requestID, payload: payload) else {
                return
            }
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.handleWebSocketFailure(error, socket: socket, generation: generation, legID: legID)
                }
            }
            recordDiagnosticRequest(requestID, type: type)
        case .quic:
            guard let quicConnection,
                  let data = packetData(type: type, requestID: requestID, payload: payload) else {
                return
            }
            Task { [weak self, weak quicConnection] in
                do {
                    if quicConnection != nil,
                       self?.isCurrentLeg(generation: generation, legID: legID, kind: .quic) == true {
                        self?.recordDiagnosticRequest(requestID, type: type)
                    }
                    try await quicConnection?.sendLine(data)
                } catch {
                    await MainActor.run { [weak self] in
                        self?.handleQUICFailure(
                            error,
                            connection: quicConnection,
                            generation: generation,
                            legID: legID
                        )
                    }
                }
            }
        case nil:
            return
        }
    }

    private func recordDiagnosticRequest(_ requestID: String, type: String) {
        let operation: RealtimeConnectionDiagnostic.Operation
        switch type {
        case "connect": operation = .connect
        case "subscribe_channel": operation = .subscribeChannel
        case "ping": operation = .ping
        default: operation = .unproven
        }
        diagnosticRequests.record(requestID, operation: operation)
    }

    func packetData(type: String, requestID: String, payload: [String: Any]) -> Data? {
        try? wireCodec.encodeJSONObject([
            "type": type,
            "request_id": requestID,
            "payload": payload
        ])
    }

    private func packetText(type: String, requestID: String, payload: [String: Any]) -> String? {
        guard let data = packetData(type: type, requestID: requestID, payload: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
    func makeFrameDecoder() -> RealtimeFrameDecoder { RealtimeFrameDecoder(codec: wireCodec) }

    func handle(_ data: Data, generation: UInt64, legID: UInt64) {
        guard let frame = RealtimeFrameDecoder.decode(.data(data), using: wireCodec) else { return }
        handle(frame, generation: generation, legID: legID)
    }

    func handle(_ message: URLSessionWebSocketTask.Message, generation: UInt64, legID: UInt64) {
        guard let input = RealtimeFrameInput(message),
              let frame = RealtimeFrameDecoder.decode(input, using: wireCodec) else { return }
        handle(frame, generation: generation, legID: legID)
    }

    func handle(_ frame: RealtimeDecodedFrame, generation: UInt64, legID: UInt64, admission: IncomingAdmission? = nil, cancelled: Bool = false) {
        guard connectionGeneration == generation,
              activeLegID == legID else {
            RealtimeMessageFlowSignpost.retiredTransport(type: frame.envelope.type)
            recordStaleEnvelopeDiagnostic(frame.envelope, generation: generation)
            return
        }
        guard !cancelled else { return } // Retired errors above retain the original safe diagnostic.
        if let expansion = frame.expansion {
            if expansion.didDropInput {
                print(
                    "[JHT Realtime] batch_bounded visited=\(expansion.visitedElements) malformed=\(expansion.malformedElements) depth_drop=\(expansion.droppedForDepth) limit_drop=\(expansion.droppedForLimit)"
                )
            }
            for envelope in expansion.frames {
                handleFlattened(envelope, generation: generation, legID: legID, admission: admission)
            }
            return
        }
        handleFlattened(frame.envelope, generation: generation, legID: legID, admission: admission)
    }
    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END

    // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023: use the actual handshake ID, never the diagnostic ring buffer.
    func matchesActiveConnectRequest(_ requestID: String?) -> Bool {
        guard let requestID, !requestID.isEmpty else { return false }
        return requestID == activeConnectRequestID
    }

    @discardableResult
    private func handleFlattened(
        _ envelope: RealtimeEnvelope,
        generation: UInt64,
        legID: UInt64,
        admission: IncomingAdmission? = nil,
        prepareOnly: Bool = false // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
    ) -> RealtimeEnvelopeDelivery? {
        guard connectionGeneration == generation,
              activeLegID == legID else {
            RealtimeMessageFlowSignpost.retiredTransport(type: envelope.type)
            recordStaleEnvelopeDiagnostic(envelope, generation: generation)
            return nil
        }
        let observedTypes = ["error", "connect_ack", "pong", "subscribe_ack", "message", "message_push", "send_ack"]
        let observation: RealtimeEnvelopeDiagnosticObservation?
        if observedTypes.contains(envelope.type) {
            let rawCode = envelope.payload["code"]?.stringValue ?? ""
            let stage: RealtimeConnectionDiagnostic.Stage = envelope.type == "error"
                // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023
                ? (RealtimeErrorScopePolicy.isConnectionFailure(code: rawCode, envelope: envelope,
                    matchesConnectRequest: matchesActiveConnectRequest(envelope.requestID)) ? .auth : .server)
                : (envelope.type == "connect_ack" ? .auth : .response)
            var event = makeDiagnostic(stage, result: envelope.type == "error" ? .serverError(rawCode) : .responseObserved)
            event.serverCode = .from(envelope)
            (event.operation, event.correlation) = diagnosticRequests.lookup(envelope.requestID)
            event.handling = .notDelivered
            observation = RealtimeEnvelopeDiagnosticObservation(event: event, scopeEpoch: diagnosticScopeEpoch)
        } else {
            observation = nil
        }
        observation?.messageFlow = RealtimeMessageFlowSignpost.arrival(type: envelope.type)
        let previousObservation = currentEnvelopeDiagnostic
        currentEnvelopeDiagnostic = observation
        var deferredDelivery = false // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
        defer {
            if !deferredDelivery { observation?.messageFlow?.finishIfNotHandedOff() }
            currentEnvelopeDiagnostic = previousObservation
            if let observation, !deferredDelivery {
                finishDiagnostic(observation.event, scopeEpoch: observation.scopeEpoch)
            }
        }
        switch envelope.type {
        case "connect_ack":
            guard connectionState == .awaitingAck,
                  let expectedRequestID = activeConnectRequestID,
                  envelope.requestID == expectedRequestID else {
                observation?.event.handling = .requestRejected
                return nil
            }
            observation?.event.result = .acknowledged
            observation?.event.handling = .acknowledged
            DebugConsoleDiagnostics.trace("[JHT Realtime] connect_ack transport=\(Self.transportName(activeTransportKind))")
            acknowledgementDeadlineTask?.cancel()
            acknowledgementDeadlineTask = nil
            connectedSinceUptime = ProcessInfo.processInfo.systemUptime
            transition(to: .connected)
            reconnectAttempt = 0
            resetHeartbeatState()
            startHeartbeat(generation: generation, legID: legID)
            onConnected?()
        case "pong":
            guard connectionState == .connected else {
                observation?.event.handling = .connectionStateRejected
                return nil
            }
            resetHeartbeatState()
            observation?.event.handling = .pongAccepted
        case "subscribe_ack":
            guard connectionState == .connected else {
                observation?.event.handling = .connectionStateRejected
                return nil
            }
            let channelID = envelope.payload["channel_id"]?.stringValue ?? ""
            let channelType = envelope.payload["channel_type"]?.stringValue ?? ""
            if !channelID.isEmpty, !channelType.isEmpty {
                subscribedChannels.insert("\(channelType)|\(channelID)")
            }
            observation?.event.handling = .subscriptionAccepted
        case "batch":
            return nil
        default:
            guard connectionState == .connected else {
                observation?.messageFlow?.finish(.connectionRejected)
                observation?.event.handling = .connectionStateRejected
                return nil
            }
            // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
            // Revalidate the original App ingest binding after the worker await, before dedupe.
            if let rejection = admission?() {
                observation?.messageFlow?.finish(.admissionRejected)
                observation?.event.handling = rejection
                return nil
            }
            // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
			if let dedupeKey = realtimeEnvelopeDedupeKey(envelope),
			   !continuity.accept(messageID: dedupeKey) {
                observation?.messageFlow?.finish(.transportDuplicate)
                observation?.event.handling = .duplicateRejected
                return nil
            }
            observation?.event.handling = onEnvelope == nil && !prepareOnly ? .noHandler : .appCallbackReturned
            if prepareOnly { // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
                deferredDelivery = true
                return RealtimeEnvelopeDelivery(envelope: envelope, observation: observation)
            }
            onEnvelope?(envelope)
        }
        return nil
    }

    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_BEGIN
    struct RealtimeDeliveryContext: Sendable { let generation: UInt64; let legID: UInt64 }
    func isCurrentDelivery(_ context: RealtimeDeliveryContext) -> Bool {
        connectionGeneration == context.generation && activeLegID == context.legID
    }
    struct RealtimeEnvelopeDelivery {
        let envelope: RealtimeEnvelope
        let observation: RealtimeEnvelopeDiagnosticObservation?
    }
    func withEnvelopeDiagnostic(_ observation: RealtimeEnvelopeDiagnosticObservation?, _ operation: () -> Void) {
        let previous = currentEnvelopeDiagnostic; currentEnvelopeDiagnostic = observation
        defer { currentEnvelopeDiagnostic = previous }
        operation()
    }
    func handleSerial(_ frame: RealtimeDecodedFrame, generation: UInt64, legID: UInt64,
                      admission: IncomingAdmission?, cancelled: Bool) async {
        guard connectionGeneration == generation, activeLegID == legID, !cancelled else {
            handle(frame, generation: generation, legID: legID, admission: admission, cancelled: cancelled); return
        }
        if let expansion = frame.expansion, expansion.didDropInput {
            print("[JHT Realtime] batch_bounded visited=\(expansion.visitedElements) malformed=\(expansion.malformedElements) depth_drop=\(expansion.droppedForDepth) limit_drop=\(expansion.droppedForLimit)")
        }
        for envelope in frame.expansion?.frames ?? [frame.envelope] {
            if Task.isCancelled {
                handle(RealtimeDecodedFrame(envelope: envelope, expansion: nil), generation: generation,
                       legID: legID, admission: admission, cancelled: true)
                continue
            }
            if let consumer = onSerialEnvelope {
                guard let delivery = handleFlattened(envelope, generation: generation, legID: legID,
                    admission: admission, prepareOnly: true) else { continue }
                await consumer(delivery.envelope, delivery.observation,
                    RealtimeDeliveryContext(generation: generation, legID: legID))
                delivery.observation?.messageFlow?.finishIfNotHandedOff()
                if let observation = delivery.observation { finishDiagnostic(observation.event, scopeEpoch: observation.scopeEpoch) }
            } else { handleFlattened(envelope, generation: generation, legID: legID, admission: admission) }
        }
    }
    // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110_END

    private func recordStaleEnvelopeDiagnostic(_ envelope: RealtimeEnvelope, generation: UInt64) {
        guard envelope.type == "error" else { return }
        var event = RealtimeConnectionDiagnostic(generation: generation, stage: .server,
            result: .serverError(envelope.payload["code"]?.stringValue ?? ""), transport: .none, elapsedMS: 0)
        event.serverCode = .from(envelope)
        event.handling = .staleConnectionRejected
        event.currentAtReceipt = false
        // No lookup against the current leg's request IDs or current session.
        publishDiagnostic(event, scopeEpoch: nil)
    }

    func transition(to state: RealtimeConnectionState) {
        connectionState = state
    }

    func nextRequestID(type: String) -> String {
        let requestID = requestIDProvider(type).trimmingCharacters(in: .whitespacesAndNewlines)
        return requestID.isEmpty ? "\(type)-\(UUID().uuidString)" : requestID
    }

    private func handleNetworkPathStatus(_ status: RealtimeNetworkPathStatus) {
        let previousStatus = lastNetworkPathStatus
        lastNetworkPathStatus = status
        guard previousStatus == .unsatisfied, status == .satisfied else { return }
        reconnectImmediatelyAfterNetworkChange()
    }

    private func reconnectImmediatelyAfterNetworkChange() {
        guard canReconnect?() == true else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        let hadActiveLeg = socket != nil || quicConnection != nil || quicConnectTask != nil
        if hadActiveLeg {
            connectionGeneration &+= 1
            stopActiveLeg()
            onDisconnected?()
        } else {
            transition(to: .idle)
        }
        startFromProvider()
    }
}
// WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END

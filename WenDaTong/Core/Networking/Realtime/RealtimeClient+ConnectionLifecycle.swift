import CryptoKit
import Foundation
import Network

@MainActor
extension RealtimeClient {
    func startWebSocket(request: RealtimeConnectionRequest, generation: UInt64) {
        guard connectionGeneration == generation,
              socket == nil,
              quicConnection == nil,
              quicConnectTask == nil else {
            return
        }
        activeLegID &+= 1
        let legID = activeLegID
        let connectRequestID = nextRequestID(type: "connect")
        activeConnectRequestID = connectRequestID
        activeTransportKind = .webSocket
        transition(to: .dialing)
        guard scheduleAcknowledgementDeadline(generation: generation, legID: legID, kind: .webSocket) else {
            handleActiveLegFailure(
                RealtimeClientError.generationDeadlineExceeded,
                retryAfter: nil,
                generation: generation,
                legID: legID,
                kind: .webSocket,
                permitsQUICFallback: false
            )
            return
        }

        DebugConsoleDiagnostics.trace("[JHT Realtime] start_ws url=\(Self.redactedEndpointSummary(request.url)) ip_hint=\(request.webSocketDialMetadata != nil)")
        let newSocket = transport.webSocketTask(with: request)
        socket = newSocket
        newSocket.resume()
        recordDiagnostic(.start, result: .started)
        transition(to: .awaitingAck)
        guard sendConnectOverWebSocket(
            token: request.token,
            requestID: connectRequestID,
            socket: newSocket,
            generation: generation,
            legID: legID
        ) else {
            return
        }

        let decoder = makeFrameDecoder() // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
        receiveTask = Task { [weak self, weak newSocket] in
            guard let newSocket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await newSocket.receive()
                    let admission = self?.captureIncomingAdmission?()
                    guard let input = RealtimeFrameInput(message) else { continue }
                    let frame = await decoder.decode(input)
                    if let frame {
                        if self?.onSerialEnvelope != nil {
                            await self?.handleSerial(frame, generation: generation, legID: legID, admission: admission, cancelled: Task.isCancelled)
                        } else { self?.handle(frame, generation: generation, legID: legID, admission: admission, cancelled: Task.isCancelled) }
                    } // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
                    guard !Task.isCancelled else { return }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.handleWebSocketFailure(
                            error,
                            socket: newSocket,
                            generation: generation,
                            legID: legID
                        )
                    }
                    return
                }
            }
        }
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
    }

    func startQUIC(request: RealtimeQUICConnectionRequest, generation: UInt64) {
        guard connectionGeneration == generation else { return }
        activeLegID &+= 1
        let legID = activeLegID
        activeConnectRequestID = nextRequestID(type: "connect")
        activeTransportKind = .quic
        transition(to: .dialing)
        guard scheduleAcknowledgementDeadline(generation: generation, legID: legID, kind: .quic) else {
            handleActiveLegFailure(
                RealtimeClientError.generationDeadlineExceeded,
                retryAfter: nil,
                generation: generation,
                legID: legID,
                kind: .quic,
                permitsQUICFallback: false
            )
            return
        }
        DebugConsoleDiagnostics.trace("[JHT Realtime] start_quic host=\(request.host) path=\(request.path)")
        let connectOperation: @Sendable () async throws -> RealtimeQUICConnectioning
        if let attemptProvider = quicTransport as? RealtimeQUICConnectAttemptProviding {
            let attempt = attemptProvider.makeConnectAttempt(request)
            quicConnectCancellation = { attempt.cancel() }
            connectOperation = { try await attempt.connect() }
        } else {
            let quicTransport = self.quicTransport
            quicConnectCancellation = nil
            connectOperation = { try await quicTransport.connect(request) }
        }
        quicConnectTask = Task { [weak self] in
            guard let self else { return }
            if self.isCurrentLeg(generation: generation, legID: legID, kind: .quic) {
                self.recordDiagnostic(.start, result: .started)
            }
            do {
                let connection = try await connectOperation()
                guard !Task.isCancelled else {
                    connection.cancel()
                    return
                }
                await MainActor.run { [weak self] in
                    self?.finishQUICConnection(
                        connection,
                        token: request.token,
                        generation: generation,
                        legID: legID
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.handleQUICFailure(error, connection: nil, generation: generation, legID: legID)
                }
            }
        }
    }

    private func finishQUICConnection(
        _ connection: RealtimeQUICConnectioning,
        token: String,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .quic),
              socket == nil else {
            connection.cancel()
            return
        }
        quicConnectTask = nil
        quicConnectCancellation = nil
        quicConnection = connection
        transition(to: .awaitingAck)
        guard let connectRequestID = activeConnectRequestID,
              let data = packetData(
                type: "connect",
                requestID: connectRequestID,
                payload: connectPayload(token: token)
              ) else {
            handleQUICFailure(
                RealtimeClientError.connectFrameEncodingFailed,
                connection: connection,
                generation: generation,
                legID: legID
            )
            return
        }

        let decoder = makeFrameDecoder() // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
        receiveTask = Task { [weak self, weak connection] in
            guard let connection else { return }
            do {
                if self?.isCurrentLeg(generation: generation, legID: legID, kind: .quic) == true {
                    self?.diagnosticRequests.record(connectRequestID, operation: .connect)
                }
                try await connection.sendLine(data)
                await MainActor.run {
                    DebugConsoleDiagnostics.trace("[JHT Realtime] connect_frame_sent transport=quic")
                }
                while !Task.isCancelled {
                    let data = try await connection.receiveLine()
                    let admission = self?.captureIncomingAdmission?()
                    let frame = await decoder.decode(.data(data))
                    if let frame {
                        if self?.onSerialEnvelope != nil {
                            await self?.handleSerial(frame, generation: generation, legID: legID, admission: admission, cancelled: Task.isCancelled)
                        } else { self?.handle(frame, generation: generation, legID: legID, admission: admission, cancelled: Task.isCancelled) }
                    } // WDT_IOS1_REALTIME_BACKGROUND_COMPUTE_20261110
                    guard !Task.isCancelled else { return }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.handleQUICFailure(
                        error,
                        connection: connection,
                        generation: generation,
                        legID: legID
                    )
                }
            }
        }
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
    }

    func fallbackToWebSocketAfterQUICFailure(
        _ error: Error,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .quic),
              !didFallbackToWebSocket,
              let request = activeRequest else {
            return
        }
        didFallbackToWebSocket = true
        acknowledgementDeadlineTask?.cancel()
        acknowledgementDeadlineTask = nil
        let cancelConnect = quicConnectCancellation
        quicConnectCancellation = nil
        cancelConnect?()
        let connectTask = quicConnectTask
        quicConnectTask = nil
        connectTask?.cancel()
        receiveTask?.cancel()
        receiveTask = nil
        quicConnection?.cancel()
        quicConnection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activeConnectRequestID = nil
        activeTransportKind = nil
        resetHeartbeatState()
        transition(to: .dialing)
        onQUICFallbackToWebSocket?(error)
        startWebSocket(request: request, generation: generation)
    }

    func stopActiveLeg() {
        diagnosticRequests.reset()
        acknowledgementDeadlineTask?.cancel()
        acknowledgementDeadlineTask = nil
        let cancelConnect = quicConnectCancellation
        quicConnectCancellation = nil
        cancelConnect?()
        quicConnectTask?.cancel()
        quicConnectTask = nil
        quicConnection?.cancel()
        quicConnection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        activeTransportKind = nil
        connectedSinceUptime = nil
        subscriptionFramesSent = 0
        subscriptionSendTask?.cancel()
        subscriptionSendTask = nil
        pendingSubscriptions = []
        pendingSubscriptionKeys.removeAll()
        activeConnectRequestID = nil
        generationDeadlineNanoseconds = nil
        subscribedChannels.removeAll()
        resetHeartbeatState()
        transition(to: .idle)
    }

    func handleWebSocketFailure(
        _ error: Error,
        socket failedSocket: RealtimeWebSocketTasking,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .webSocket),
              socket === failedSocket else {
            return
        }
        handleActiveLegFailure(
            error,
            retryAfter: failedSocket.realtimeRetryAfter,
            generation: generation,
            legID: legID,
            kind: .webSocket
        )
    }

    func handleQUICFailure(
        _ error: Error,
        connection failedConnection: RealtimeQUICConnectioning?,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .quic) else {
            failedConnection?.cancel()
            return
        }
        if let failedConnection,
           let quicConnection,
           quicConnection !== failedConnection {
            failedConnection.cancel()
            return
        }
        handleActiveLegFailure(
            error,
            retryAfter: nil,
            generation: generation,
            legID: legID,
            kind: .quic
        )
    }

    func logSocketFailure(_ error: Error, kind: RealtimeActiveTransportKind) {
        let failure = error as NSError
        let signature = "transport=\(Self.transportName(kind)) domain=\(failure.domain) code=\(failure.code)"
        let uptime = ProcessInfo.processInfo.systemUptime
        if !DebugConsoleDiagnostics.verbose,
           let previous = lastSocketFailureLog,
           previous.signature == signature,
           uptime - previous.uptime < 60 {
            suppressedSocketFailureLogs += 1
            return
        }

        let connectedMS = connectedSinceUptime.map { String(Int((uptime - $0) * 1_000)) } ?? "none"
        let urlSessionSocket = socket as? URLSessionWebSocketTask
        let closeCode = urlSessionSocket?.closeCode
        let close = closeCode.flatMap { $0 == .invalid ? nil : String($0.rawValue) } ?? "none"
        let reason = urlSessionSocket?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        let reasonCategory = Self.webSocketCloseReasonCategory(reason)
        print("[JHT Realtime] socket_failure \(signature) phase=\(connectionState.rawValue) connected_ms=\(connectedMS) close_code=\(close) close_category=\(reasonCategory) subscribe_sent=\(subscriptionFramesSent) subscribe_acked=\(subscribedChannels.count) repeated_logs_suppressed=\(suppressedSocketFailureLogs)")
        lastSocketFailureLog = (signature, uptime)
        suppressedSocketFailureLogs = 0
    }

    private static func webSocketCloseReasonCategory(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "none" }
        let normalized = reason.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if ["rate limit", "too many", "flood", "throttl"].contains(where: { normalized.contains($0) }) {
            return "rate_limit"
        }
        if ["duplicate", "replaced", "superseded", "kicked"].contains(where: { normalized.contains($0) }) {
            return "connection_replaced"
        }
        if ["unauthorized", "forbidden", "token", "session"].contains(where: { normalized.contains($0) }) {
            return "authorization_or_session"
        }
        if normalized.contains("subscri") { return "subscription" }
        return "unclassified"
    }

    func scheduleReconnect(retryAfterFloor: TimeInterval? = nil) {
        guard reconnectTask == nil, canReconnect?() == true else { return }
        let cap = reconnectCaps[min(reconnectAttempt, reconnectCaps.count - 1)]
        let sample = reconnectJitterProvider()
        let jitterFraction = sample.isFinite ? min(max(sample, 0), 1) : 0
        let jitteredDelay = cap * jitterFraction
        let delaySeconds = max(jitteredDelay, retryAfterFloor ?? 0)
        let delayNanoseconds = reconnectDelayNanoseconds(seconds: delaySeconds)
        reconnectAttempt += 1
        transition(to: .backoff)
        onReconnectScheduled?(delaySeconds)
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.connectionState == .backoff else {
                    return
                }
                self.reconnectTask = nil
                self.transition(to: .idle)
                self.startFromProvider()
            }
        }
    }

    func startHeartbeat(generation: UInt64, legID: UInt64) {
        resetHeartbeatState()
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.heartbeatIntervalNanoseconds ?? 25_000_000_000)
                } catch {
                    return
                }
                await MainActor.run { [weak self] in
                    self?.sendHeartbeatPing(generation: generation, legID: legID)
                }
            }
        }
    }

    private func sendHeartbeatPing(generation: UInt64, legID: UInt64) {
        guard connectionGeneration == generation,
              activeLegID == legID,
              connectionState == .connected else {
            return
        }
        if awaitingPong {
            missedPongCount += 1
            if missedPongCount >= maximumMissedPongs {
                let error = RealtimeClientError.acknowledgementTimeout(
                    transport: Self.transportName(activeTransportKind)
                )
                switch activeTransportKind {
                case .webSocket:
                    if let socket {
                        handleWebSocketFailure(error, socket: socket, generation: generation, legID: legID)
                    }
                case .quic:
                    handleQUICFailure(error, connection: quicConnection, generation: generation, legID: legID)
                case nil:
                    break
                }
                return
            }
        }
        awaitingPong = true
        sendPacket(type: "ping", payload: [:])
    }

    func resetHeartbeatState() {
        awaitingPong = false
        missedPongCount = 0
    }

    private func scheduleAcknowledgementDeadline(
        generation: UInt64,
        legID: UInt64,
        kind: RealtimeActiveTransportKind
    ) -> Bool {
        acknowledgementDeadlineTask?.cancel()
        guard connectionGeneration == generation,
              let generationDeadlineNanoseconds else {
            return false
        }
        let nowNanoseconds = monotonicClock.nowNanoseconds()
        guard generationDeadlineNanoseconds > nowNanoseconds else {
            return false
        }
        let legDeadlineNanoseconds = addingWithoutOverflow(
            acknowledgementTimeoutNanoseconds,
            to: nowNanoseconds
        )
        let effectiveDeadlineNanoseconds = min(legDeadlineNanoseconds, generationDeadlineNanoseconds)
        let exhaustsGenerationBudget = effectiveDeadlineNanoseconds == generationDeadlineNanoseconds
        let monotonicClock = self.monotonicClock
        acknowledgementDeadlineTask = Task { [weak self] in
            do {
                try await monotonicClock.sleep(untilNanoseconds: effectiveDeadlineNanoseconds)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentLeg(generation: generation, legID: legID, kind: kind),
                      self.connectionState != .connected else {
                    return
                }
                let error = RealtimeClientError.acknowledgementTimeout(
                    transport: Self.transportName(kind)
                )
                self.handleActiveLegFailure(
                    exhaustsGenerationBudget
                        ? RealtimeClientError.generationDeadlineExceeded
                        : error,
                    retryAfter: nil,
                    generation: generation,
                    legID: legID,
                    kind: kind,
                    permitsQUICFallback: !exhaustsGenerationBudget
                )
            }
        }
        return true
    }

    func hasRemainingGenerationBudget(generation: UInt64) -> Bool {
        guard connectionGeneration == generation,
              let generationDeadlineNanoseconds else {
            return false
        }
        return monotonicClock.nowNanoseconds() < generationDeadlineNanoseconds
    }

    func addingWithoutOverflow(_ interval: UInt64, to instant: UInt64) -> UInt64 {
        let (deadline, overflow) = instant.addingReportingOverflow(interval)
        return overflow ? UInt64.max : deadline
    }

    func isCurrentLeg(
        generation: UInt64,
        legID: UInt64,
        kind: RealtimeActiveTransportKind
    ) -> Bool {
        connectionGeneration == generation
            && activeLegID == legID
            && activeTransportKind == kind
    }

    func sanitizedConnectionRequest(_ request: RealtimeConnectionRequest) -> RealtimeConnectionRequest {
        RealtimeConnectionRequest(
            url: request.url,
            token: request.token,
            webSocketDialMetadata: request.webSocketDialMetadata,
            quicRequest: request.quicRequest.map { sanitizedQUICRequest($0, token: request.token) }
        )
    }

    func sanitizedQUICRequest(
        _ request: RealtimeQUICConnectionRequest,
        token: String
    ) -> RealtimeQUICConnectionRequest {
        let sanitizedPath = RealtimeEndpointURLSanitizer.removingQueryAndFragment(fromPath: request.path)
        return RealtimeQUICConnectionRequest(
            host: request.host,
            dialHost: request.dialHost,
            port: request.port,
            path: sanitizedPath.isEmpty ? "/im/quic" : sanitizedPath,
            token: token,
            alpn: request.alpn,
            tlsServerName: request.tlsServerName,
            connectTimeoutNanoseconds: request.connectTimeoutNanoseconds
        )
    }

    func retryAfterFloor(error: Error, transportValue: TimeInterval?) -> TimeInterval? {
        let errorValue = (error as? RealtimeRetryAfterProviding)?.realtimeRetryAfter
        let values = [transportValue, errorValue]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 >= 0 }
        guard let availableValue = values.max() else { return nil }
        return min(availableValue, 300)
    }

    private func reconnectDelayNanoseconds(seconds: TimeInterval) -> UInt64 {
        let scaledSeconds = max(0, seconds * reconnectDelayScale)
        guard scaledSeconds > 0 else { return 0 }
        return UInt64((scaledSeconds * 1_000_000_000).rounded())
    }

    private static func redactedEndpointSummary(_ url: URL) -> String {
        let sanitizedURL = RealtimeEndpointURLSanitizer.removingCredentials(from: url)
        guard var components = URLComponents(url: sanitizedURL, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid-url>"
    }

    static func transportName(_ kind: RealtimeActiveTransportKind?) -> String {
        switch kind {
        case .webSocket:
            return "websocket"
        case .quic:
            return "quic"
        case nil:
            return "none"
        }
    }

    private static func redactedErrorSummary(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        return String(reflecting: type(of: error))
    }
}

import Foundation
import Combine
import Network
import XCTest
@testable import WenDaTong

let realtimeTestSecond: UInt64 = 1_000_000_000

func deterministicRealtimeRequestID(type: String) -> String {
    "\(type)-1"
}

func realtimeEnvelopeString(type: String, requestID: String? = nil) -> String {
    let resolvedRequestID = requestID
        ?? (type == "connect_ack" ? deterministicRealtimeRequestID(type: "connect") : deterministicRealtimeRequestID(type: type))
    return #"{"type":"\#(type)","request_id":"\#(resolvedRequestID)","payload":{}}"#
}

func sentPacketTypes(_ socket: FakeRealtimeWebSocketTask) -> [String] {
    socket.sentStrings().compactMap { text in
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["type"] as? String
    }
}

func sentPacketPayload(_ socket: FakeRealtimeWebSocketTask) throws -> [String: Any]? {
    let packet = try XCTUnwrap(socket.sentStrings().first)
    let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
    return object?["payload"] as? [String: Any]
}

func sentPacketPayloadToken(_ sentStrings: [String]) throws -> String? {
    let packet = try XCTUnwrap(sentStrings.first)
    let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
    let payload = object?["payload"] as? [String: Any]
    return payload?["token"] as? String
}

func discoveryQUICRequest(token: String, path: String = "/im/quic") -> RealtimeQUICConnectionRequest {
    RealtimeQUICConnectionRequest(
        host: "im-quic.example.cn",
        port: 19006,
        path: path,
        token: token,
        alpn: "im_quic_json_v1",
        tlsServerName: "im-quic.example.cn",
        connectTimeoutNanoseconds: 3_000_000_000
    )
}

func sentPacketPayloadToken(_ connection: FakeRealtimeQUICConnection) throws -> String? {
    let packet = try XCTUnwrap(connection.sentLineStrings().first)
    let object = try JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any]
    let payload = object?["payload"] as? [String: Any]
    return payload?["token"] as? String
}

struct CapturedWebSocketHeader: Equatable {
    let name: String
    let value: String
}

final class TestRealtimeMonotonicClock: RealtimeMonotonicClock, @unchecked Sendable {
    private struct Sleeper {
        let deadlineNanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentNanoseconds: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []

    func nowNanoseconds() -> UInt64 {
        lock.withLock { currentNanoseconds }
    }

    func sleep(untilNanoseconds deadlineNanoseconds: UInt64) async throws {
        let sleeperID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum RegistrationResult {
                    case registered
                    case elapsed
                    case cancelled
                }
                let result = lock.withLock { () -> RegistrationResult in
                    if cancelledSleeperIDs.remove(sleeperID) != nil {
                        return .cancelled
                    }
                    if deadlineNanoseconds <= currentNanoseconds {
                        return .elapsed
                    }
                    sleepers[sleeperID] = Sleeper(
                        deadlineNanoseconds: deadlineNanoseconds,
                        continuation: continuation
                    )
                    return .registered
                }
                switch result {
                case .registered:
                    break
                case .elapsed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let sleeper = self.sleepers.removeValue(forKey: sleeperID) else {
                    self.cancelledSleeperIDs.insert(sleeperID)
                    return nil
                }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(toNanoseconds targetNanoseconds: UInt64) {
        let dueSleepers = lock.withLock { () -> [Sleeper] in
            currentNanoseconds = max(currentNanoseconds, targetNanoseconds)
            let dueIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadlineNanoseconds <= currentNanoseconds ? id : nil
            }
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        dueSleepers.forEach { $0.continuation.resume() }
    }

    func pendingDeadlines() -> [UInt64] {
        lock.withLock {
            sleepers.values.map(\.deadlineNanoseconds).sorted()
        }
    }
}

final class WebSocketUpgradeRejectionServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.jianhuitong.tests.websocket-429")
    private let lock = NSLock()
    private let responseData: Data
    private var connections: [NWConnection] = []

    init(retryAfter: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        responseData = Data(
            "HTTP/1.1 429 Too Many Requests\r\nRetry-After: \(retryAfter)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
        )
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              let port = listener.port,
              let url = URL(string: "ws://127.0.0.1:\(port.rawValue)/im/ws") else {
            throw URLError(.timedOut)
        }
        return url
    }

    func cancel() {
        let activeConnections = lock.withLock { () -> [NWConnection] in
            let activeConnections = connections
            connections.removeAll()
            return activeConnections
        }
        activeConnections.forEach { $0.forceCancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            connections.append(connection)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state,
                  let self,
                  let connection else {
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak connection] _, _, _, _ in
                guard let self, let connection else { return }
                connection.send(content: self.responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: queue)
    }
}

func captureNetworkWebSocketClientHeaders(pathAndQuery: String, httpHost: String) throws -> [CapturedWebSocketHeader] {
    final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var headers: [CapturedWebSocketHeader] = []
        private var connections: [NWConnection] = []

        func setHeaders(_ headers: [(name: String, value: String)]) {
            lock.withLock {
                self.headers = headers.map {
                    CapturedWebSocketHeader(name: $0.name, value: $0.value)
                }
            }
        }

        func keepAlive(_ connection: NWConnection) {
            lock.withLock {
                connections.append(connection)
            }
        }

        func capturedHeaders() -> [CapturedWebSocketHeader] {
            lock.withLock { headers }
        }
    }

    let queue = DispatchQueue(label: "com.jianhuitong.tests.websocket-host-capture")
    let box = CaptureBox()
    let serverWebSocketOptions = NWProtocolWebSocket.Options()
    let captured = DispatchSemaphore(value: 0)
    serverWebSocketOptions.setClientRequestHandler(queue) { _, headers in
        box.setHeaders(headers)
        captured.signal()
        return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
    }
    let listenerParameters = NWParameters.tcp
    listenerParameters.defaultProtocolStack.applicationProtocols.insert(serverWebSocketOptions, at: 0)
    let listener = try NWListener(using: listenerParameters, on: .any)
    let ready = DispatchSemaphore(value: 0)
    let accepted = DispatchSemaphore(value: 0)

    listener.stateUpdateHandler = { state in
        if case .ready = state {
            ready.signal()
        }
    }
    listener.newConnectionHandler = { connection in
        box.keepAlive(connection)
        accepted.signal()
        connection.start(queue: queue)
    }
    listener.start(queue: queue)
    XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
    let port = try XCTUnwrap(listener.port)

    let websocketOptions = NWProtocolWebSocket.Options()
    websocketOptions.setAdditionalHeaders([("Host", httpHost)])
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)
    let endpointURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port.rawValue)\(pathAndQuery)"))
    let connection = NWConnection(to: .url(endpointURL), using: parameters)
    connection.start(queue: queue)
    XCTAssertEqual(accepted.wait(timeout: .now() + 3), .success)
    XCTAssertEqual(captured.wait(timeout: .now() + 3), .success)
    connection.cancel()
    listener.cancel()
    return box.capturedHeaders()
}

final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let socket: FakeRealtimeWebSocketTask
    private let lock = NSLock()
    private var urls: [URL] = []
    private var requests: [RealtimeConnectionRequest] = []

    init(socket: FakeRealtimeWebSocketTask) {
        self.socket = socket
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        lock.withLock {
            urls.append(url)
        }
        return socket
    }

    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking {
        lock.withLock {
            requests.append(request)
            urls.append(request.url)
        }
        return socket
    }

    func requestedURLs() -> [URL] {
        lock.withLock { urls }
    }

    func requestedRequests() -> [RealtimeConnectionRequest] {
        lock.withLock { requests }
    }
}

final class FakeRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveMessages: [URLSessionWebSocketTask.Message]
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var resumes = 0
    private var cancellationCodes: [URLSessionWebSocketTask.CloseCode] = []

    init(receiveMessages: [URLSessionWebSocketTask.Message] = []) {
        self.receiveMessages = receiveMessages
    }

    func resume() {
        lock.withLock {
            resumes += 1
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            cancellationCodes.append(closeCode)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            if let message = lock.withLock({ receiveMessages.isEmpty ? nil : receiveMessages.removeFirst() }) {
                return message
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            sent.append(message)
        }
        completionHandler(nil)
    }

    func sentStrings() -> [String] {
        lock.withLock {
            sent.compactMap { message in
                if case let .string(text) = message {
                    return text
                }
                return nil
            }
        }
    }

    func enqueue(_ message: URLSessionWebSocketTask.Message) {
        lock.withLock {
            receiveMessages.append(message)
        }
    }

    func resumeCount() -> Int {
        lock.withLock { resumes }
    }

    func cancelCount() -> Int {
        lock.withLock { cancellationCodes.count }
    }

    func cancelCodes() -> [URLSessionWebSocketTask.CloseCode] {
        lock.withLock { cancellationCodes }
    }
}

final class LeakyRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedMessages: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var cancels = 0

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            cancels += 1
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let immediateMessage = lock.withLock { () -> URLSessionWebSocketTask.Message? in
                if !queuedMessages.isEmpty {
                    return queuedMessages.removeFirst()
                }
                receiver = continuation
                return nil
            }
            if let immediateMessage {
                continuation.resume(returning: immediateMessage)
            }
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        lock.withLock {
            sent.append(message)
        }
        completionHandler(nil)
    }

    func emit(_ message: URLSessionWebSocketTask.Message) {
        let continuation = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            guard let receiver else {
                queuedMessages.append(message)
                return nil
            }
            self.receiver = nil
            return receiver
        }
        continuation?.resume(returning: message)
    }

    func hasPendingReceiver() -> Bool {
        lock.withLock { receiver != nil }
    }

    func sentStrings() -> [String] {
        lock.withLock {
            sent.compactMap { message in
                if case let .string(text) = message {
                    return text
                }
                return nil
            }
        }
    }

    func cancelCount() -> Int {
        lock.withLock { cancels }
    }
}

final class SequencedRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [RealtimeWebSocketTasking]
    private var urls: [URL] = []

    init(tasks: [RealtimeWebSocketTasking]) {
        self.tasks = tasks
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        lock.withLock {
            precondition(!tasks.isEmpty, "missing sequenced realtime task")
            urls.append(url)
            return tasks.removeFirst()
        }
    }

    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking {
        webSocketTask(with: request.url)
    }

    func requestedURLs() -> [URL] {
        lock.withLock { urls }
    }
}

final class FailingRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let retryAfter: TimeInterval?

    init(retryAfter: TimeInterval? = nil) {
        self.retryAfter = retryAfter
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        lock.withLock {
            urls.append(url)
        }
        return FailingRealtimeWebSocketTask(retryAfter: retryAfter)
    }

    func requestedURLs() -> [URL] {
        lock.withLock { urls }
    }
}

private final class FailingRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    let realtimeRetryAfter: TimeInterval?

    init(retryAfter: TimeInterval?) {
        self.realtimeRetryAfter = retryAfter
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        await Task.yield()
        throw URLError(.notConnectedToInternet)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
    }
}

final class FakeRealtimeNetworkMonitor: RealtimeNetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RealtimeNetworkPathStatus) -> Void)?

    func start(pathUpdateHandler: @escaping @Sendable (RealtimeNetworkPathStatus) -> Void) {
        lock.withLock {
            handler = pathUpdateHandler
        }
    }

    func cancel() {
        lock.withLock {
            handler = nil
        }
    }

    func emit(_ status: RealtimeNetworkPathStatus) {
        let currentHandler = lock.withLock { handler }
        currentHandler?(status)
    }
}

final class FakeRealtimeQUICTransport: RealtimeQUICTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<RealtimeQUICConnectioning, Error>
    private var capturedRequests: [RealtimeQUICConnectionRequest] = []

    init(result: Result<RealtimeQUICConnectioning, Error>) {
        self.result = result
    }

    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        lock.withLock {
            capturedRequests.append(request)
        }
        switch result {
        case .success(let connection):
            return connection
        case .failure(let error):
            throw error
        }
    }

    func requests() -> [RealtimeQUICConnectionRequest] {
        lock.withLock { capturedRequests }
    }
}

final class HangingRealtimeQUICTransport: RealtimeQUICTransporting, RealtimeQUICConnectAttemptProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [RealtimeQUICConnectionRequest] = []
    private var continuation: CheckedContinuation<RealtimeQUICConnectioning, Error>?
    private var didCancel = false
    private var cancellations = 0

    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        try await makeConnectAttempt(request).connect()
    }

    func makeConnectAttempt(_ request: RealtimeQUICConnectionRequest) -> RealtimeQUICConnectAttempt {
        lock.withLock {
            capturedRequests.append(request)
        }
        return RealtimeQUICConnectAttempt(
            operation: { [weak self] in
                guard let self else { throw RealtimeQUICError.connectionCancelled }
                return try await self.waitForever()
            },
            cancellationHandler: { [weak self] in
                self?.cancelUnderlyingConnection()
            }
        )
    }

    func requestCount() -> Int {
        lock.withLock { capturedRequests.count }
    }

    func cancelCount() -> Int {
        lock.withLock { cancellations }
    }

    private func waitForever() async throws -> RealtimeQUICConnectioning {
        try await withCheckedThrowingContinuation { continuation in
            let isAlreadyCancelled = lock.withLock { () -> Bool in
                guard !didCancel else { return true }
                self.continuation = continuation
                return false
            }
            if isAlreadyCancelled {
                continuation.resume(throwing: RealtimeQUICError.connectionCancelled)
            }
        }
    }

    private func cancelUnderlyingConnection() {
        let continuation = lock.withLock { () -> CheckedContinuation<RealtimeQUICConnectioning, Error>? in
            guard !didCancel else { return nil }
            didCancel = true
            cancellations += 1
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: RealtimeQUICError.connectionCancelled)
    }
}

final class ClockAdvancingFailingRealtimeQUICTransport: RealtimeQUICTransporting, RealtimeQUICConnectAttemptProviding, @unchecked Sendable {
    private let clock: TestRealtimeMonotonicClock
    private let failureTimeNanoseconds: UInt64
    private let lock = NSLock()
    private var cancellations = 0
    private var didCancel = false

    init(clock: TestRealtimeMonotonicClock, failureTimeNanoseconds: UInt64) {
        self.clock = clock
        self.failureTimeNanoseconds = failureTimeNanoseconds
    }

    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        try await makeConnectAttempt(request).connect()
    }

    func makeConnectAttempt(_ request: RealtimeQUICConnectionRequest) -> RealtimeQUICConnectAttempt {
        RealtimeQUICConnectAttempt(
            operation: { [clock, failureTimeNanoseconds] in
                clock.advance(toNanoseconds: failureTimeNanoseconds)
                throw RealtimeQUICError.connectionFailed("test failure")
            },
            cancellationHandler: { [weak self] in
                self?.cancelUnderlyingConnection()
            }
        )
    }

    func cancelCount() -> Int {
        lock.withLock { cancellations }
    }

    private func cancelUnderlyingConnection() {
        lock.withLock {
            guard !didCancel else { return }
            didCancel = true
            cancellations += 1
        }
    }
}

final class FakeRealtimeQUICConnection: RealtimeQUICConnectioning, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveLines: [Data]
    private var sentLines: [Data] = []
    private var cancels = 0

    init(receiveLines: [Data] = []) {
        self.receiveLines = receiveLines
    }

    func receiveLine() async throws -> Data {
        if let line = lock.withLock({ receiveLines.isEmpty ? nil : receiveLines.removeFirst() }) {
            return line
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        throw CancellationError()
    }

    func sendLine(_ data: Data) async throws {
        lock.withLock {
            sentLines.append(data)
        }
    }

    func cancel() {
        lock.withLock {
            cancels += 1
        }
    }

    func sentLineStrings() -> [String] {
        lock.withLock {
            sentLines.compactMap { String(data: $0, encoding: .utf8) }
        }
    }

    func cancelCount() -> Int {
        lock.withLock { cancels }
    }
}

final class RecordingRealtimeWireCodec: WireCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedDecodedTypeNames: [String] = []
    private var capturedDecodedInputTexts: [String] = []
    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
    private let passthrough: Bool
    private let onDecode: (@Sendable (String, Bool) -> Void)?
    init(passthrough: Bool = false, onDecode: (@Sendable (String, Bool) -> Void)? = nil) {
        self.passthrough = passthrough
        self.onDecode = onDecode
    }
    // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END

    func encodeJSONObject(_ object: Any) throws -> Data {
        try JSONWireCodec().encodeJSONObject(object)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let typeName = String(describing: T.self)
        lock.withLock {
            capturedDecodedTypeNames.append(typeName)
            capturedDecodedInputTexts.append(String(data: data, encoding: .utf8) ?? "")
        }
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
        onDecode?(String(decoding: data, as: UTF8.self), Thread.isMainThread)
        if passthrough { return try JSONWireCodec().decode(type, from: data) }
        // WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END
        guard T.self == RealtimeEnvelope.self else {
            throw RealtimeTestWireCodecError.unsupportedType(typeName)
        }
        return RealtimeEnvelope(type: "connect_ack", requestID: "req-1", payload: [:]) as! T
    }

    func decodedTypeNames() -> [String] {
        lock.withLock { capturedDecodedTypeNames }
    }

    func decodedInputTexts() -> [String] {
        lock.withLock { capturedDecodedInputTexts }
    }
}

private enum RealtimeTestWireCodecError: Error {
    case unsupportedType(String)
}

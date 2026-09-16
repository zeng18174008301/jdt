import Foundation
import Network

protocol RealtimeWebSocketTasking: AnyObject, Sendable {
    var realtimeRetryAfter: TimeInterval? { get }

    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension RealtimeWebSocketTasking {
    var realtimeRetryAfter: TimeInterval? { nil }
}

protocol RealtimeWebSocketTransporting: AnyObject, Sendable {
    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking
    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking
}

extension RealtimeWebSocketTransporting {
    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking {
        webSocketTask(with: request.url)
    }
}

final class URLSessionRealtimeTransport: RealtimeWebSocketTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func webSocketTask(with url: URL) -> RealtimeWebSocketTasking {
        session.webSocketTask(with: RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: url))
    }

    func webSocketTask(with request: RealtimeConnectionRequest) -> RealtimeWebSocketTasking {
        guard let metadata = request.webSocketDialMetadata,
              let task = NWRealtimeWebSocketTask(url: request.url, metadata: metadata) else {
            return webSocketTask(with: request.url)
        }
        return task
    }
}

struct RealtimeQUICConnectAttempt: Sendable {
    private let operation: @Sendable () async throws -> RealtimeQUICConnectioning
    private let cancellationHandler: @Sendable () -> Void

    init(
        operation: @escaping @Sendable () async throws -> RealtimeQUICConnectioning,
        cancellationHandler: @escaping @Sendable () -> Void
    ) {
        self.operation = operation
        self.cancellationHandler = cancellationHandler
    }

    func connect() async throws -> RealtimeQUICConnectioning {
        try await withTaskCancellationHandler(
            operation: operation,
            onCancel: cancellationHandler
        )
    }

    func cancel() {
        cancellationHandler()
    }
}

protocol RealtimeQUICConnectAttemptProviding: AnyObject, Sendable {
    func makeConnectAttempt(_ request: RealtimeQUICConnectionRequest) -> RealtimeQUICConnectAttempt
}

extension NWRealtimeQUICTransport: RealtimeQUICConnectAttemptProviding {
    func makeConnectAttempt(_ request: RealtimeQUICConnectionRequest) -> RealtimeQUICConnectAttempt {
        let options = NWProtocolQUIC.Options(alpn: [request.alpn])
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, request.tlsServerName)
        let parameters = NWParameters(quic: options)
        let port = NWEndpoint.Port(rawValue: request.port) ?? .https
        let connection = NWConnection(host: NWEndpoint.Host(request.dialHost), port: port, using: parameters)
        let operation = NWRealtimeQUICConnectOperation(
            connection: connection,
            timeoutNanoseconds: request.connectTimeoutNanoseconds
        )
        return RealtimeQUICConnectAttempt(
            operation: { try await operation.connect() },
            cancellationHandler: { operation.cancel() }
        )
    }
}

private final class NWRealtimeQUICConnectOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let timeoutNanoseconds: UInt64
    private let queue = DispatchQueue(label: "com.jianhuitong.realtime.quic-connect")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var didCompleteReadiness = false
    private var isCancelled = false

    init(connection: NWConnection, timeoutNanoseconds: UInt64) {
        self.connection = connection
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func connect() async throws -> RealtimeQUICConnectioning {
        do {
            try await waitUntilReady()
            try Task.checkCancellation()
            guard lock.withLock({ !isCancelled }) else {
                throw RealtimeQUICError.connectionCancelled
            }
            return NWRealtimeQUICConnection(connection: connection)
        } catch {
            cancel()
            throw error
        }
    }

    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !isCancelled else { return nil }
            isCancelled = true
            let continuation = readyContinuation
            readyContinuation = nil
            return continuation
        }
        connection.forceCancel()
        continuation?.resume(throwing: RealtimeQUICError.connectionCancelled)
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let shouldReject = lock.withLock { () -> Bool in
                guard !isCancelled else { return true }
                readyContinuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handleConnectionState(state)
                }
                connection.start(queue: queue)
                return false
            }
            if shouldReject {
                continuation.resume(throwing: RealtimeQUICError.connectionCancelled)
                return
            }
            guard timeoutNanoseconds > 0 else { return }
            let seconds = Double(timeoutNanoseconds) / 1_000_000_000
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.completeReadiness(.failure(RealtimeQUICError.connectionTimeout))
            }
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            completeReadiness(.success(()))
        case .failed(let error):
            completeReadiness(.failure(RealtimeQUICError.connectionFailed(error.localizedDescription)))
        case .cancelled:
            completeReadiness(.failure(RealtimeQUICError.connectionCancelled))
        default:
            break
        }
    }

    private func completeReadiness(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !isCancelled, !didCompleteReadiness else { return nil }
            didCompleteReadiness = true
            let continuation = readyContinuation
            readyContinuation = nil
            return continuation
        }
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

extension URLSessionWebSocketTask: RealtimeWebSocketTasking {
    var realtimeRetryAfter: TimeInterval? {
        guard let response = response as? HTTPURLResponse,
              let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        return RealtimeRetryAfterParser.delaySeconds(from: value)
    }
}

enum RealtimeEndpointURLSanitizer {
    private static let credentialQueryNames: Set<String> = [
        "access_token",
        "authorization",
        "im_token",
        "token"
    ]

    static func removingCredentials(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.user = nil
        components.password = nil
        let retainedQueryItems = (components.queryItems ?? []).filter { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !credentialQueryNames.contains(name)
        }
        components.queryItems = retainedQueryItems.isEmpty ? nil : retainedQueryItems
        return components.url ?? url
    }

    static func canonicalIMWebSocketURLRemovingCredentials(from url: URL) -> URL {
        let sanitizedURL = removingCredentials(from: url)
        guard var components = URLComponents(url: sanitizedURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            return sanitizedURL
        }
        components.percentEncodedPath = "/im/ws"
        return components.url ?? sanitizedURL
    }

    static func removingQueryAndFragment(fromPath path: String) -> String {
        let queryIndex = path.firstIndex(of: "?")
        let fragmentIndex = path.firstIndex(of: "#")
        let endIndex = [queryIndex, fragmentIndex].compactMap { $0 }.min() ?? path.endIndex
        return String(path[..<endIndex])
    }
}

enum RealtimeRetryAfterParser {
    static func delaySeconds(from rawValue: String, now: Date = Date()) -> TimeInterval? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

enum RealtimeEndpointAddressValidator {
    static func isIPAddress(_ value: String) -> Bool {
        normalizedIPLiteral(value) != nil
    }

    static func normalizedIPLiteral(_ value: String) -> String? {
        let normalized = normalizedIPAddress(value)
        guard IPv4Address(normalized) != nil || IPv6Address(normalized) != nil else {
            return nil
        }
        return normalized
    }

    static func isDomainName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              !isIPAddress(trimmed),
              trimmed.range(of: #"^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$"#, options: .regularExpression) != nil,
              !trimmed.contains(".."),
              !trimmed.contains(":"),
              !trimmed.contains("/") else {
            return false
        }
        return true
    }

    private static func normalizedIPAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           trimmed.hasSuffix("]"),
           trimmed.count > 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

enum NWRealtimeWebSocketError: Error, Equatable {
    case invalidDialURL
    case connectionCancelled
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
}

final class NWRealtimeWebSocketTask: RealtimeWebSocketTasking, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jianhuitong.realtime.websocket.nw")
    private let lock = NSLock()
    private var started = false

    init?(url: URL, metadata: RealtimeWebSocketDialMetadata) {
        guard let dialURL = Self.dialURL(for: url, metadata: metadata) else {
            return nil
        }
        let parameters = Self.parameters(metadata: metadata)
        connection = NWConnection(to: .url(dialURL), using: parameters)
    }

    var realtimeRetryAfter: TimeInterval? {
        // A rejected Upgrade does not expose connection-wide WebSocket metadata. The
        // successful-handshake-only additionalServerHeaders API cannot recover a 429 here.
        nil
    }

    func resume() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        connection.start(queue: queue)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connection.cancel()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            let frame = try await receiveFrame()
            switch frame {
            case .message(let message):
                return message
            case .control:
                continue
            }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let content: Data
        let opcode: NWProtocolWebSocket.Opcode
        switch message {
        case .string(let text):
            content = Data(text.utf8)
            opcode = .text
        case .data(let data):
            content = data
            opcode = .binary
        @unknown default:
            completionHandler(NWRealtimeWebSocketError.sendFailed("unsupported websocket message"))
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: "im-realtime-websocket-message",
            metadata: [metadata]
        )
        connection.send(content: content, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error {
                completionHandler(NWRealtimeWebSocketError.sendFailed(error.localizedDescription))
            } else {
                completionHandler(nil)
            }
        })
    }

    static func dialURL(for url: URL, metadata: RealtimeWebSocketDialMetadata) -> URL? {
        let sanitizedURL = RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: url)
        guard var components = URLComponents(url: sanitizedURL, resolvingAgainstBaseURL: false),
              components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "wss" else {
            return nil
        }
        components.host = metadata.dialHost
        components.port = Int(metadata.port)
        return components.url
    }

    static func parameters(metadata: RealtimeWebSocketDialMetadata, secure: Bool = true) -> NWParameters {
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.setAdditionalHeaders([("Host", metadata.httpHost)])

        let parameters: NWParameters
        if secure {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, metadata.tlsServerName)
            parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        return parameters
    }

    private enum ReceivedFrame {
        case message(URLSessionWebSocketTask.Message)
        case control
    }

    private func receiveFrame() async throws -> ReceivedFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReceivedFrame, Error>) in
            connection.receiveMessage { data, context, isComplete, error in
                if let error {
                    continuation.resume(throwing: NWRealtimeWebSocketError.receiveFailed(error.localizedDescription))
                    return
                }
                do {
                    if let message = try Self.decodeReceivedMessage(data: data, context: context, isComplete: isComplete) {
                        continuation.resume(returning: .message(message))
                    } else {
                        continuation.resume(returning: .control)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func decodeReceivedMessage(
        data: Data?,
        context: NWConnection.ContentContext?,
        isComplete: Bool
    ) throws -> URLSessionWebSocketTask.Message? {
        guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
            if isComplete, data == nil {
                throw NWRealtimeWebSocketError.connectionCancelled
            }
            throw NWRealtimeWebSocketError.receiveFailed("missing websocket metadata")
        }
        switch metadata.opcode {
        case .text:
            guard let data,
                  let text = String(data: data, encoding: .utf8) else {
                throw NWRealtimeWebSocketError.receiveFailed("invalid text frame")
            }
            return .string(text)
        case .binary:
            return .data(data ?? Data())
        case .ping, .pong:
            return nil
        case .close:
            throw NWRealtimeWebSocketError.connectionCancelled
        case .cont:
            throw NWRealtimeWebSocketError.receiveFailed("fragmented websocket frame")
        @unknown default:
            throw NWRealtimeWebSocketError.receiveFailed("unknown websocket frame")
        }
    }
}

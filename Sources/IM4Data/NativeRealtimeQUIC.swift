// WDT_IOS1_DATA17_NATIVE_REALTIME_20261111_BEGIN
import Foundation
import Network

public struct RealtimeQUICConnectionRequest: Sendable, Equatable {
    public let host: String
    public let dialHost: String
    public let port: UInt16
    public let path: String
    public let token: String
    public let alpn: String
    public let tlsServerName: String
    public let connectTimeoutNanoseconds: UInt64

    public init(
        host: String,
        dialHost: String? = nil,
        port: UInt16,
        path: String,
        token: String,
        alpn: String,
        tlsServerName: String,
        connectTimeoutNanoseconds: UInt64
    ) {
        self.host = host
        if let normalizedDialHost = dialHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalizedDialHost.isEmpty {
            self.dialHost = normalizedDialHost
        } else {
            self.dialHost = host
        }
        self.port = port
        self.path = path
        self.token = token
        self.alpn = alpn
        self.tlsServerName = tlsServerName
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
    }
}

public enum RealtimeQUICError: Error, Equatable {
    case connectionTimeout
    case connectionCancelled
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
}

// Preserve the original Foundation bridge after the implementation moves modules.
extension RealtimeQUICError: CustomNSError {
    public static let errorDomain = "BlueStoneIM.RealtimeQUICError"

    public var errorCode: Int {
        switch self {
        case .connectionFailed: return 0
        case .sendFailed: return 1
        case .receiveFailed: return 2
        case .connectionTimeout: return 3
        case .connectionCancelled: return 4
        }
    }
}


public protocol RealtimeQUICConnectioning: AnyObject, Sendable {
    func receiveLine() async throws -> Data
    func sendLine(_ data: Data) async throws
    func cancel()
}

public protocol RealtimeQUICTransporting: AnyObject, Sendable {
    func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning
}

public final class NWRealtimeQUICTransport: RealtimeQUICTransporting {
    public init() {}

    public func connect(_ request: RealtimeQUICConnectionRequest) async throws -> RealtimeQUICConnectioning {
        let options = NWProtocolQUIC.Options(alpn: [request.alpn])
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, request.tlsServerName)
        let parameters = NWParameters(quic: options)
        let port = NWEndpoint.Port(rawValue: request.port) ?? .https
        let connection = NWConnection(host: NWEndpoint.Host(request.dialHost), port: port, using: parameters)
        let quicConnection = NWRealtimeQUICConnection(connection: connection)
        do {
            try await quicConnection.start(timeoutNanoseconds: request.connectTimeoutNanoseconds)
            return quicConnection
        } catch {
            quicConnection.cancel()
            throw error
        }
    }
}

final class NWRealtimeQUICConnection: RealtimeQUICConnectioning, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jianhuitong.realtime.quic")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var bufferedData = Data()
    private var isCancelled = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(timeoutNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                readyContinuation = continuation
            }
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionState(state)
            }
            if timeoutNanoseconds > 0 {
                let seconds = Double(timeoutNanoseconds) / 1_000_000_000
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.completeReady(.failure(RealtimeQUICError.connectionTimeout))
                }
            }
            connection.start(queue: queue)
        }
    }

    func receiveLine() async throws -> Data {
        while true {
            if let line = popBufferedLine() {
                return line
            }
            let chunk = try await receiveChunk()
            guard !chunk.isEmpty else {
                throw RealtimeQUICError.receiveFailed("empty frame")
            }
            lock.withLock {
                bufferedData.append(chunk)
            }
        }
    }

    func sendLine(_ data: Data) async throws {
        var line = data
        line.append(0x0a)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: line, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RealtimeQUICError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
        connection.cancel()
        completeReady(.failure(RealtimeQUICError.connectionCancelled))
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            completeReady(.success(()))
        case .failed(let error):
            completeReady(.failure(RealtimeQUICError.connectionFailed(error.localizedDescription)))
        case .cancelled:
            completeReady(.failure(RealtimeQUICError.connectionCancelled))
        default:
            break
        }
    }

    private func completeReady(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
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

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: RealtimeQUICError.receiveFailed(error.localizedDescription))
                    return
                }
                if isComplete {
                    continuation.resume(throwing: RealtimeQUICError.connectionCancelled)
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    private func popBufferedLine() -> Data? {
        lock.withLock {
            guard let newlineIndex = bufferedData.firstIndex(of: 0x0a) else { return nil }
            let line = bufferedData[..<newlineIndex]
            bufferedData.removeSubrange(bufferedData.startIndex...newlineIndex)
            var result = Data(line)
            if result.last == 0x0d {
                result.removeLast()
            }
            return result
        }
    }
}
// WDT_IOS1_DATA17_NATIVE_REALTIME_20261111_END

// WDT_IOS1_DATA17_NATIVE_REALTIME_20261111_BEGIN
import Foundation
import Network

public struct RealtimeConnectionRequest: Sendable {
    public let url: URL
    public let token: String
    public let webSocketDialMetadata: RealtimeWebSocketDialMetadata?
    public let quicRequest: RealtimeQUICConnectionRequest?

    public init(
        url: URL,
        token: String,
        webSocketDialMetadata: RealtimeWebSocketDialMetadata? = nil,
        quicRequest: RealtimeQUICConnectionRequest? = nil
    ) {
        self.url = RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: url)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.webSocketDialMetadata = webSocketDialMetadata
        self.quicRequest = quicRequest
    }
}

public struct RealtimeWebSocketDialMetadata: Sendable, Equatable {
    public let dialHost: String
    public let port: UInt16
    public let tlsServerName: String
    public let httpHost: String

    public init?(dialHost: String, port: Int, tlsServerName: String, httpHost: String) {
        guard let normalizedDialHost = RealtimeEndpointAddressValidator.normalizedIPLiteral(dialHost) else {
            return nil
        }
        let normalizedTLSServerName = tlsServerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedHTTPHost = httpHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let port = UInt16(exactly: port),
              RealtimeEndpointAddressValidator.isDomainName(normalizedTLSServerName),
              RealtimeEndpointAddressValidator.isDomainName(normalizedHTTPHost) else {
            return nil
        }
        self.dialHost = normalizedDialHost
        self.port = port
        self.tlsServerName = normalizedTLSServerName
        self.httpHost = normalizedHTTPHost
    }
}

public enum RealtimeNetworkPathStatus: Sendable, Equatable {
    case satisfied
    case unsatisfied
}

public protocol RealtimeNetworkMonitoring: AnyObject, Sendable {
    func start(pathUpdateHandler: @escaping @Sendable (RealtimeNetworkPathStatus) -> Void)
    func cancel()
}

public final class NWPathRealtimeNetworkMonitor: RealtimeNetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.jianhuitong.realtime.path-monitor")

    public init() {}

    public func start(pathUpdateHandler: @escaping @Sendable (RealtimeNetworkPathStatus) -> Void) {
        monitor.pathUpdateHandler = { path in
            pathUpdateHandler(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}
// WDT_IOS1_DATA17_NATIVE_REALTIME_20261111_END

import Foundation
import Network

struct RealtimeQUICConfiguration: Sendable, Equatable {
    static let defaultALPN = "im_quic_json_v1"

    let isEnabled: Bool
    let endpointURL: URL?
    let tlsServerName: String?
    let alpn: String
    let connectTimeoutNanoseconds: UInt64

    init(
        isEnabled: Bool = false,
        endpointURL: URL? = nil,
        tlsServerName: String? = nil,
        alpn: String = RealtimeQUICConfiguration.defaultALPN,
        connectTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.isEnabled = isEnabled
        self.endpointURL = endpointURL
        self.tlsServerName = tlsServerName
        self.alpn = alpn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultALPN
            : alpn.trimmingCharacters(in: .whitespacesAndNewlines)
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
    }

    static func load(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        allowLocalOverride: Bool = Self.allowsLocalConfigurationOverride,
        discoveryFeatureGateEnabled: Bool = Self.defaultDiscoveryFeatureGateEnabled
    ) -> RealtimeQUICConfiguration {
        guard allowLocalOverride else {
            return RealtimeQUICConfiguration(
                isEnabled: discoveryFeatureGateEnabled,
                endpointURL: nil,
                tlsServerName: nil,
                alpn: Self.defaultALPN
            )
        }

        var enabled = discoveryFeatureGateEnabled || defaults.bool(forKey: Keys.enabled)
        var urlString = defaults.string(forKey: Keys.url)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var tlsServerName = defaults.string(forKey: Keys.tlsServerName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var alpn = defaults.string(forKey: Keys.alpn)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultALPN
        var timeoutMs = defaults.integer(forKey: Keys.connectTimeoutMs)

        for argument in arguments {
            if argument == "--quic-poc-enabled" {
                enabled = true
            } else if argument == "--quic-poc-disabled" {
                enabled = false
            } else if argument.hasPrefix("--quic-poc-url=") {
                enabled = true
                urlString = String(argument.dropFirst("--quic-poc-url=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if argument.hasPrefix("--quic-poc-tls-server-name=") {
                tlsServerName = String(argument.dropFirst("--quic-poc-tls-server-name=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if argument.hasPrefix("--quic-poc-alpn=") {
                alpn = String(argument.dropFirst("--quic-poc-alpn=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if argument.hasPrefix("--quic-poc-timeout-ms=") {
                timeoutMs = Int(String(argument.dropFirst("--quic-poc-timeout-ms=".count))) ?? timeoutMs
            }
        }

        let endpointURL = urlString.isEmpty ? nil : URL(string: urlString)
        return RealtimeQUICConfiguration(
            isEnabled: enabled,
            endpointURL: endpointURL,
            tlsServerName: tlsServerName?.isEmpty == true ? nil : tlsServerName,
            alpn: alpn,
            connectTimeoutNanoseconds: Self.clampedConnectTimeoutNanoseconds(milliseconds: timeoutMs)
        )
    }

    static var allowsLocalConfigurationOverride: Bool {
        #if DEBUG || REALTIME_QUIC_LOCAL_CONFIGURATION_ENABLED
        true
        #else
        false
        #endif
    }

    static var defaultDiscoveryFeatureGateEnabled: Bool {
        #if REALTIME_QUIC_DISCOVERY_ENABLED
        true
        #else
        false
        #endif
    }

    func connectionRequest(token: String) -> RealtimeQUICConnectionRequest? {
        guard let endpointURL else { return nil }
        return connectionRequest(endpointURL: endpointURL, token: token)
    }

    func connectionRequest(
        endpointURL: URL,
        token: String,
        tlsServerName requestedTLSServerName: String? = nil,
        dialHost requestedDialHost: String? = nil,
        defaultPort: Int? = nil,
        defaultPath: String = "/im/quic",
        connectTimeoutNanoseconds requestedConnectTimeoutNanoseconds: UInt64? = nil
    ) -> RealtimeQUICConnectionRequest? {
        guard isEnabled,
              let components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["quic", "imquic", "https"].contains(scheme),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              !Self.isIPAddress(host) else {
            return nil
        }
        let serverName = (requestedTLSServerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? host
        guard !Self.isIPAddress(serverName) else {
            return nil
        }
        let dialHost = (requestedDialHost?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? host
        if dialHost != host, !Self.isIPAddress(dialHost) {
            return nil
        }
        let portValue = components.port ?? defaultPort ?? 443
        guard let port = UInt16(exactly: portValue) else { return nil }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }
        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPath = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return RealtimeQUICConnectionRequest(
            host: host,
            dialHost: dialHost,
            port: port,
            path: path.isEmpty ? (fallbackPath.isEmpty ? "/im/quic" : fallbackPath) : path,
            token: trimmedToken,
            alpn: alpn,
            tlsServerName: serverName,
            connectTimeoutNanoseconds: requestedConnectTimeoutNanoseconds ?? connectTimeoutNanoseconds
        )
    }

    static func clampedConnectTimeoutNanoseconds(milliseconds: Int) -> UInt64 {
        let clampedTimeoutMs = min(max(milliseconds <= 0 ? 3_000 : milliseconds, 500), 15_000)
        return UInt64(clampedTimeoutMs) * 1_000_000
    }

    static func isIPAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.contains(":") && trimmed.range(of: #"^[0-9A-Fa-f:\[\]]+$"#, options: .regularExpression) != nil
    }

    private enum Keys {
        static let enabled = "im2.realtime.quic.enabled"
        static let url = "im2.realtime.quic.url"
        static let tlsServerName = "im2.realtime.quic.tlsServerName"
        static let alpn = "im2.realtime.quic.alpn"
        static let connectTimeoutMs = "im2.realtime.quic.connectTimeoutMs"
    }
}

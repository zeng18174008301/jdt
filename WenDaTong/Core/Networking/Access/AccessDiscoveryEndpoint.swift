import CryptoKit
import Foundation
import Network

struct RemoteAccessDiscoveryEndpoint: Codable, Equatable, Sendable {
    let id: String
    let usage: String
    let protocolValue: String
    let url: String
    let host: String
    let port: Int
    let path: String?
    let resolvedIPs: [String]
    let tlsServerName: String?
    let httpHost: String?
    let dialMode: String?
    let priority: Int
    let weight: Int
    let region: String?
    let provider: String?
    let network: String
    let tls: Bool?
    let auth: String?
    let connectTimeoutMs: Int?
    let heartbeatSeconds: Int?
    let minStableSeconds: Int?
    let failbackAfterSeconds: Int?
    let cooldownSeconds: Int?
    let maxParallelRace: Int?
    let status: String
    let protectedResourceID: String?
    let protectedResourceType: String?
    let protectionEvidenceHash: String?
    let protectionExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case usage
        case protocolValue = "protocol"
        case url
        case host
        case port
        case path
        case resolvedIPs = "resolved_ips"
        case tlsServerName = "tls_server_name"
        case httpHost = "http_host"
        case dialMode = "dial_mode"
        case priority
        case weight
        case region
        case provider
        case network
        case tls
        case auth
        case connectTimeoutMs = "connect_timeout_ms"
        case heartbeatSeconds = "heartbeat_seconds"
        case minStableSeconds = "min_stable_seconds"
        case failbackAfterSeconds = "failback_after_seconds"
        case cooldownSeconds = "cooldown_seconds"
        case maxParallelRace = "max_parallel_race"
        case status
        case protectedResourceID = "protected_resource_id"
        case protectedResourceType = "protected_resource_type"
        case protectionEvidenceHash = "protection_evidence_hash"
        case protectionExpiresAt = "protection_expires_at"
    }

    init(
        id: String,
        usage: String,
        protocolValue: String,
        url: String,
        host: String,
        port: Int,
        path: String? = nil,
        resolvedIPs: [String] = [],
        tlsServerName: String? = nil,
        httpHost: String? = nil,
        dialMode: String? = nil,
        priority: Int,
        weight: Int,
        region: String? = nil,
        provider: String? = nil,
        network: String,
        tls: Bool? = nil,
        auth: String? = nil,
        connectTimeoutMs: Int? = nil,
        heartbeatSeconds: Int? = nil,
        minStableSeconds: Int? = nil,
        failbackAfterSeconds: Int? = nil,
        cooldownSeconds: Int? = nil,
        maxParallelRace: Int? = nil,
        status: String,
        protectedResourceID: String? = nil,
        protectedResourceType: String? = nil,
        protectionEvidenceHash: String? = nil,
        protectionExpiresAt: String? = nil
    ) {
        self.id = id
        self.usage = usage
        self.protocolValue = protocolValue
        self.url = url
        self.host = host
        self.port = port
        self.path = path
        self.resolvedIPs = resolvedIPs
        self.tlsServerName = tlsServerName
        self.httpHost = httpHost
        self.dialMode = dialMode
        self.priority = priority
        self.weight = weight
        self.region = region
        self.provider = provider
        self.network = network
        self.tls = tls
        self.auth = auth
        self.connectTimeoutMs = connectTimeoutMs
        self.heartbeatSeconds = heartbeatSeconds
        self.minStableSeconds = minStableSeconds
        self.failbackAfterSeconds = failbackAfterSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxParallelRace = maxParallelRace
        self.status = status
        self.protectedResourceID = protectedResourceID
        self.protectedResourceType = protectedResourceType
        self.protectionEvidenceHash = protectionEvidenceHash
        self.protectionExpiresAt = protectionExpiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        usage = try c.decode(String.self, forKey: .usage)
        protocolValue = try c.decode(String.self, forKey: .protocolValue)
        url = try c.decode(String.self, forKey: .url)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        resolvedIPs = try c.decodeIfPresent([String].self, forKey: .resolvedIPs) ?? []
        tlsServerName = try c.decodeIfPresent(String.self, forKey: .tlsServerName)
        httpHost = try c.decodeIfPresent(String.self, forKey: .httpHost)
        dialMode = try c.decodeIfPresent(String.self, forKey: .dialMode)
        priority = try c.decode(Int.self, forKey: .priority)
        weight = try c.decode(Int.self, forKey: .weight)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        network = try c.decode(String.self, forKey: .network)
        tls = try c.decodeIfPresent(Bool.self, forKey: .tls)
        auth = try c.decodeIfPresent(String.self, forKey: .auth)
        connectTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .connectTimeoutMs)
        heartbeatSeconds = try c.decodeIfPresent(Int.self, forKey: .heartbeatSeconds)
        minStableSeconds = try c.decodeIfPresent(Int.self, forKey: .minStableSeconds)
        failbackAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .failbackAfterSeconds)
        cooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .cooldownSeconds)
        maxParallelRace = try c.decodeIfPresent(Int.self, forKey: .maxParallelRace)
        status = try c.decode(String.self, forKey: .status)
        protectedResourceID = try c.decodeIfPresent(String.self, forKey: .protectedResourceID)
        protectedResourceType = try c.decodeIfPresent(String.self, forKey: .protectedResourceType)
        protectionEvidenceHash = try c.decodeIfPresent(String.self, forKey: .protectionEvidenceHash)
        protectionExpiresAt = try c.decodeIfPresent(String.self, forKey: .protectionExpiresAt)
    }

    var normalizedID: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedNetwork: String {
        network.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isRealtimeWebSocketCandidate: Bool {
        guard usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "im_realtime" else { return false }
        guard protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "wss" else { return false }
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "wss",
              let urlHost = components.host,
              RealtimeEndpointAddressValidator.isDomainName(urlHost),
              RealtimeEndpointAddressValidator.isDomainName(host) else {
            return false
        }
        return !normalizedID.isEmpty
    }

    func isSignedProtectedEndpointValid(at now: Date, validUntil: Date) -> Bool {
        let protocolName = protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let usageName = usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedNetwork != "direct",
              normalizedStatus == "ready" || normalizedStatus == "degraded" || normalizedStatus == "draining",
              tls == true,
              let components = URLComponents(string: url),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.host?.lowercased() == host.lowercased(),
              RealtimeEndpointAddressValidator.isDomainName(host),
              (components.port ?? ((protocolName == "wss" || protocolName == "https") ? 443 : 0)) == port,
              (protocolName == "wss" || protocolName == "quic"
                  ? usageName == "im_realtime" && auth == "im_token"
                  : protocolName == "https" && usageName == "access_discovery" && auth == "none"),
              !(protectedResourceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              !(protectedResourceType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              let evidenceHash = protectionEvidenceHash?.lowercased(),
              evidenceHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let expiresText = protectionExpiresAt,
              let protectionExpiry = ISO8601DateFormatter().date(from: expiresText),
              protectionExpiry > now, protectionExpiry >= validUntil else {
            return false
        }
        return resolvedIPs.allSatisfy(RealtimeEndpointAddressValidator.isIPAddress)
    }

    var isProductionDomainOnlyEndpoint: Bool {
        if provider == "alibaba_cloud_ga" {
            guard port == 443,
                  protocolValue != "https" || path == "/api/tenant/access/v1/endpoints" else {
                return false
            }
        }
        let exactHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host == exactHost,
              RealtimeEndpointAddressValidator.isDomainName(exactHost),
              let components = URLComponents(string: url),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.host == exactHost,
              components.percentEncodedPath == components.path,
              path == components.path,
              (components.port ?? 443) == port,
              tlsServerName == exactHost, httpHost == exactHost,
              resolvedIPs.isEmpty, dialMode == "domain_only",
              network == normalizedNetwork, normalizedNetwork != "direct",
              Self.hasProductionEndpointRole(usage: usage, protocolName: protocolValue, auth: auth),
              !Self.isProductionOriginAddress(exactHost),
              Self.hasProductionProtectedEntryBinding(
                provider: provider,
                resourceType: protectedResourceType,
                resourceID: protectedResourceID,
                host: exactHost,
                network: normalizedNetwork
              ) else {
            return false
        }
        let protocolName = protocolValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return protocolValue == protocolName.lowercased() && components.scheme == protocolName
    }

    var productionCandidateIdentity: String? {
        guard let components = URLComponents(string: url),
              components.percentEncodedPath == components.path,
              let candidateHost = components.host else {
            return nil
        }
        return [usage, protocolValue, candidateHost, String(port), components.path].joined(separator: "\u{0}")
    }

    private static func isProductionOriginAddress(_ host: String) -> Bool {
        let suffixes = [
            ".amazonaws.com", ".amazonaws.com.cn", ".compute.internal", ".internal", ".local", ".localhost"
        ]
        guard !suffixes.contains(where: host.hasSuffix) else { return true }
        let firstLabel = host.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return firstLabel.hasPrefix("internal-") || firstLabel.hasPrefix("ip-")
    }

    private static func hasProductionProtectedEntryBinding(
        provider: String?,
        resourceType: String?,
        resourceID: String?,
        host: String,
        network: String
    ) -> Bool {
        let rawProvider = provider ?? ""
        let rawResourceType = resourceType ?? ""
        let rawResourceID = resourceID ?? ""
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resourceType = rawResourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resourceID = rawResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawProvider == provider, rawResourceType == resourceType, rawResourceID == resourceID else {
            return false
        }
        if provider == "alibaba_cloud_ga", resourceType == "controlled_load_balancer" {
            let prefix = "brand-entry:"
            let digest = resourceID.dropFirst(prefix.count)
            return network == "accelerated" && !host.hasSuffix(".cloudfront.net") &&
                resourceID.hasPrefix(prefix) && digest.count == 64 &&
                digest.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                }
        }
        let loweredID = resourceID.lowercased()
        guard !["private", "origin", "alb", "elb", "ec2", "target-group", "target_group"]
            .contains(where: loweredID.contains) else {
            return false
        }
        if provider == "aws_cloudfront", resourceType == "controlled_load_balancer" {
            return network == "fallback" && host.hasSuffix(".cloudfront.net") && isCloudFrontDistributionID(resourceID)
        }
        if provider == "alibaba_cloud_esa", resourceType == "professional_high_defense" {
            return network == "accelerated" && !host.hasSuffix(".cloudfront.net") && isSafeEdgeResourceID(resourceID)
        }
        return false
    }

    private static func hasProductionEndpointRole(
        usage: String,
        protocolName: String,
        auth: String?
    ) -> Bool {
        (protocolName == "wss" && usage == "im_realtime" && auth == "im_token") ||
            (protocolName == "https" && usage == "access_discovery" && auth == "none")
    }

    private static func isCloudFrontDistributionID(_ value: String) -> Bool {
        guard (5...32).contains(value.count), value.first == "E" else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57)
        }
    }

    private static func isSafeEdgeResourceID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 65 && $0.value <= 90) ||
                ($0.value >= 48 && $0.value <= 57) || "-_.:/".unicodeScalars.contains($0)
        }
    }

    var isRealtimeQUICCandidate: Bool {
        guard usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "im_realtime" else { return false }
        guard protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "quic" else { return false }
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "quic",
              let urlHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlHost.isEmpty,
              RealtimeEndpointAddressValidator.isDomainName(urlHost),
              RealtimeEndpointAddressValidator.isDomainName(host) else {
            return false
        }
        if let tlsServerName = tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tlsServerName.isEmpty,
           !RealtimeEndpointAddressValidator.isDomainName(tlsServerName) {
            return false
        }
        if let httpHost = httpHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !httpHost.isEmpty,
           !RealtimeEndpointAddressValidator.isDomainName(httpHost) {
            return false
        }
        return !normalizedID.isEmpty
    }

    func runtimeWebSocketURL() -> URL? {
        guard isRealtimeWebSocketCandidate,
              var components = URLComponents(string: url) else {
            return nil
        }
        if (components.path.isEmpty || components.path == "/"),
           let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty {
            components.path = path.hasPrefix("/") ? path : "/\(path)"
        }
        guard let endpointURL = components.url else { return nil }
        return RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: endpointURL)
    }

    func runtimeWebSocketDialMetadata() -> RealtimeWebSocketDialMetadata? {
        guard isRealtimeWebSocketCandidate,
              let components = URLComponents(string: url),
              let urlHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              RealtimeEndpointAddressValidator.isDomainName(urlHost),
              host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == urlHost,
              dialMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "domain_or_ip_hint" else {
            return nil
        }
        let tlsName = tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hostHeader = httpHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard tlsName == urlHost,
              hostHeader == urlHost,
              RealtimeEndpointAddressValidator.isDomainName(tlsName),
              RealtimeEndpointAddressValidator.isDomainName(hostHeader),
              let dialHost = resolvedIPs
                  .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                  .first(where: { RealtimeEndpointAddressValidator.isIPAddress($0) }) else {
            return nil
        }
        return RealtimeWebSocketDialMetadata(
            dialHost: dialHost,
            port: components.port ?? port,
            tlsServerName: tlsName,
            httpHost: hostHeader
        )
    }

    func runtimeQUICConnectionRequest(
        token: String,
        configuration: RealtimeQUICConfiguration
    ) -> RealtimeQUICConnectionRequest? {
        guard isRealtimeQUICCandidate,
              let rawEndpointURL = URL(string: url) else {
            return nil
        }
        let endpointURL = RealtimeEndpointURLSanitizer.removingCredentials(from: rawEndpointURL)
        let defaultPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutNanoseconds = connectTimeoutMs.map {
            RealtimeQUICConfiguration.clampedConnectTimeoutNanoseconds(milliseconds: $0)
        }
        let resolvedDefaultPath = defaultPath.flatMap { $0.isEmpty ? nil : $0 } ?? "/im/quic"
        let dialHost = resolvedIPs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && RealtimeEndpointAddressValidator.isIPAddress($0) }
        return configuration.connectionRequest(
            endpointURL: endpointURL,
            token: token,
            tlsServerName: tlsServerName,
            dialHost: dialHost,
            defaultPort: port,
            defaultPath: resolvedDefaultPath,
            connectTimeoutNanoseconds: timeoutNanoseconds
        )
    }
}

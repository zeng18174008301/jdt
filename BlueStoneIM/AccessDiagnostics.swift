import Foundation
import SwiftUI
import Darwin
#if canImport(UIKit)
import UIKit
#endif

struct AppBuildIdentity: Equatable {
    static let unavailableText = "配置未获取"
    static let sourceCommitInfoKey = "WXTSourceCommit"
    static let buildIdentityInfoKey = "WXTBuildIdentity"

    let sourceCommit: String
    let buildIdentity: String

    init(info: [String: Any]) {
        sourceCommit = Self.validatedSourceCommit(info[Self.sourceCommitInfoKey])
            ?? Self.unavailableText
        buildIdentity = Self.validatedBuildIdentity(info[Self.buildIdentityInfoKey])
            ?? Self.unavailableText
    }

    static var current: AppBuildIdentity {
        AppBuildIdentity(info: Bundle.main.infoDictionary ?? [:])
    }

    private static func validatedSourceCommit(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (7...64).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        return value
    }

    private static func validatedBuildIdentity(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }
}

enum AccessDiagnosticsStatus: String, CaseIterable {
    case bootstrapFetching
    case merchantResolving
    case merchantDataPlane
    case discoveryFetching
    case endpointComparing
    case selectedPrimary
    case selectedFallback
    case usingCache
    case failed

    var compactText: String {
        switch self {
        case .bootstrapFetching, .merchantResolving, .discoveryFetching:
            return "接入 · 获取中"
        case .merchantDataPlane:
            return "接入 · 商户数据面"
        case .endpointComparing:
            return "接入 · 对比中"
        case .selectedPrimary:
            return "接入 · 主链路"
        case .selectedFallback:
            return "接入 · 兜底"
        case .usingCache:
            return "接入 · 缓存"
        case .failed:
            return "接入 · 失败"
        }
    }
}

struct AccessDiagnosticsSnapshot: Equatable {
    var turnAddresses = AccessDiagnosticsTurnAddresses()
    var status: AccessDiagnosticsStatus
    var appIDSummary: String
    var bootstrapHost: String
    var bootstrapFallbackHost: String
    var bootstrapCurrentHost: String
    var bootstrapTier: String
    var bootstrapState: String
    var merchantName: String
    var tenantAPIHost: String
    var merchantState: String
    var discoveryPrimaryHost: String
    var discoveryFallbackHost: String
    var discoverySource: String
    var imPrimaryHost: String
    var imFallbackHost: String
    var imCurrentHost: String
    var connectionProtocol: String
    var reason: String
    var ipHintsCount: Int
    var ipStrategy: String
    var ipPolicyNote: String
    var dnsIPSummary: String
    var currentPolicyOverlayStatus: String
    var routes: [IMRuntimeRouteService: AccessDiagnosticsDomainRoute]
    var connectionResult: RealtimeConnectionDiagnostic? = nil

    static let initial = AccessDiagnosticsSnapshot(
        status: .bootstrapFetching,
        appIDSummary: IMAPIContext.canonicalIOSAppID,
        bootstrapHost: "未获取",
        bootstrapFallbackHost: "未配置",
        bootstrapCurrentHost: "等待首次请求",
        bootstrapTier: "未命中",
        bootstrapState: "正在获取",
        merchantName: "未进入",
        tenantAPIHost: "未获取",
        merchantState: "未进入",
        discoveryPrimaryHost: "未获取",
        discoveryFallbackHost: "未配置",
        discoverySource: "未知",
        imPrimaryHost: "未获取",
        imFallbackHost: "未配置",
        imCurrentHost: "未连接",
        connectionProtocol: "WSS",
        reason: "等待接入信息",
        ipHintsCount: 0,
        ipStrategy: "按域名连接",
        ipPolicyNote: "未直连 IP",
        dnsIPSummary: "未解析",
        currentPolicyOverlayStatus: AccessDiagnosticsOverlayConfiguration.unavailable.displayText,
        routes: [:]
    )

    var compactText: String {
        status.compactText
    }

    var connectionRows: [(String, String)] {
        guard let event = connectionResult else { return [("实际结果", "尚无记录")] }
        return [("记录", event.isFailure ? "本代首错（可能随后恢复）" : "本代最近结果"),
                ("阶段", event.stage.rawValue), ("结果", event.result.label),
                ("传输", event.transport.rawValue), ("连接代次", String(event.generation)),
                ("耗时 ms", String(event.elapsedMS)), ("服务端码", event.serverCode.rawValue),
                ("实际处理码", event.handlingCode.rawValue),
                ("原请求操作", event.operation.rawValue), ("请求关联", event.correlation.rawValue),
                ("接收时范围", event.scopeMatch.rawValue), ("实际处理", event.handling.rawValue),
                ("处理后连接", event.stateAfter?.rawValue ?? "UNPROVEN"), ("处理后范围", event.scopeAfter.rawValue),
                ("处理后代次", event.generationAfter.map(String.init) ?? "UNPROVEN")]
    }

    var redactedSummary: String {
        (["当前接入域名"] + domainSections.map { section in
            let values = section.rows.map { "\($0.0)=\($0.1)" }.joined(separator: "；")
            return "\(section.title)：\(values)"
        }).joined(separator: "\n")
    }

    var clientIdentityRows: [(String, String)] {
        clientIdentityRows(buildIdentity: .current)
    }

    func clientIdentityRows(buildIdentity: AppBuildIdentity) -> [(String, String)] {
        [
            ("AppId", appIDSummary),
            ("pkgname", Bundle.main.bundleIdentifier ?? "未配置"),
            ("source commit", buildIdentity.sourceCommit),
            ("build identity", buildIdentity.buildIdentity),
            ("current-policy overlay", currentPolicyOverlayStatus)
        ]
    }

    var domainSections: [(title: String, rows: [(String, String)])] {
        // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
        [("Bootstrap", domainRows(bootstrapDomainRoute, primaryTitle: "候选 1", backupTitle: "其余候选"))] + IMRuntimeRouteService.allCases.map { service in
        // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
            (service.rawValue, domainRows(domainRoute(for: service)))
        }
    }

    var bootstrapDomainRoute: AccessDiagnosticsDomainRoute {
        AccessDiagnosticsDomainRoute(
            current: bootstrapCurrentHost,
            tier: bootstrapTier,
            primary: bootstrapHost,
            backups: bootstrapFallbackHost == "未配置" ? [] : [bootstrapFallbackHost]
        )
    }

    func domainRoute(for service: IMRuntimeRouteService) -> AccessDiagnosticsDomainRoute {
        if let route = routes[service] { return route }
        switch service {
        case .platformAPI:
            return .unresolved
        case .tenantAPI:
            return .unresolved
        case .imAPI:
            return .unresolved
        case .imRealtime:
            return AccessDiagnosticsDomainRoute(
                current: imCurrentHost,
                tier: status == .selectedFallback ? "备用域" : (imCurrentHost == "未连接" ? "未命中" : "主域"),
                primary: imPrimaryHost,
                backups: imFallbackHost == "未配置" ? [] : [imFallbackHost]
            )
        }
    }

    private func domainRows(
        _ route: AccessDiagnosticsDomainRoute,
        primaryTitle: String = "主域名",
        backupTitle: String = "备用域名"
    ) -> [(String, String)] {
        [
            ("当前命中", route.current),
            ("当前层级", route.tier),
            (primaryTitle, route.primary),
            (backupTitle, route.backupLabel)
        ]
    }
}

/// Diagnostic DNS answers, never an instruction to change the ICE route.
struct AccessDiagnosticsTurnAddresses: Equatable {
    private(set) var generation = UUID()
    private(set) var hosts: [String] = []
    private(set) var answers: [String: [String]] = [:]

    var rows: [(String, String)] {
        guard !hosts.isEmpty else { return [("解析后 IP", "未获取 TURN 配置")] }
        return [("来源", "通话配置 DNS 解析")]
            + hosts.map { host in
                let value = answers[host].map { $0.isEmpty ? "解析失败或超时" : $0.joined(separator: "、") } ?? "解析中"
                return (host, value)
            }
    }

    mutating func begin(hosts: [String]) {
        generation = UUID()
        self.hosts = hosts
        answers = [:]
    }

    mutating func apply(_ ips: [String], host: String, generation: UUID) {
        guard generation == self.generation, hosts.contains(host), answers[host] == nil else { return }
        answers[host] = Array(Set(ips.filter(Self.isIPAddress))).sorted().prefix(8).map { $0 }
    }

    static func hosts(from urls: [String]) -> [String] {
        Array(Set(urls.compactMap { raw -> String? in
            guard raw.count <= 2048, !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
                  let colon = raw.firstIndex(of: ":"), ["turn", "turns"].contains(raw[..<colon].lowercased()) else { return nil }
            var authority = String(raw[raw.index(after: colon)...])
            if authority.hasPrefix("//") { authority.removeFirst(2) }
            guard let url = URLComponents(string: "https://" + authority), url.user == nil, url.password == nil,
                  url.path.isEmpty, url.fragment == nil, let rawHost = url.host,
                  url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
            let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if isIPAddress(host) { return host }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.count <= 253, !labels.isEmpty, labels.allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }) else { return nil }
            return host
        })).sorted().prefix(8).map { $0 }
    }

    static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    static func resolve(_ host: String) async -> [String] {
        if isIPAddress(host) { return [host] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var ips = Set<String>()
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let item = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer,
                                   socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        ips.insert(String(cString: buffer))
                    }
                    cursor = item.pointee.ai_next
                }
                continuation.resume(returning: Array(ips).sorted())
            }
        }
    }
}

struct AccessDiagnosticsDomainRoute: Equatable {
    var current: String
    var tier: String
    var primary: String
    var backups: [String]

    static let unresolved = AccessDiagnosticsDomainRoute(
        current: "等待首次请求",
        tier: "未命中",
        primary: "未配置",
        backups: []
    )

    var backupLabel: String { backups.isEmpty ? "未配置" : backups.joined(separator: "、") }
}

enum AccessDiagnosticsEvent {
    case bootstrapFetching(appID: String, bootstrapHost: String, fallbackHost: String?)
    case bootstrapSucceeded(appID: String, bootstrapHost: String, fallbackHost: String?, source: String)
    case bootstrapFailed(appID: String, bootstrapHost: String, fallbackHost: String?, reason: String)
    // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
    case bootstrapRoute(primaryHost: String, fallbackHost: String?, currentHost: String, tier: IMRuntimeRouteTier, source: String)
    // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
    case merchantResolving(name: String, tenantAPIHost: String)
    case merchantEntered(name: String, tenantAPIHost: String)
    case discoveryFetching(tenantAPIHost: String)
    case discoveryResponse(RemoteAccessDiscoveryResponse, tenantAPIHost: String)
    case discoveryOutcome(AccessDiscoveryRefreshOutcome)
    case connectionComparing(fallbackURL: URL?, quicHost: String?)
    case connectionSelected(currentHost: String, protocolName: String, reason: String)
    case connectionFallback(currentHost: String, protocolName: String, reason: String)
    case runtimeRoutes(IMRuntimeRouteSnapshot)
    case routeHit(service: IMRuntimeRouteService, endpoint: String, tier: IMRuntimeRouteTier)
    case failed(reason: String)
}

enum AccessDiagnosticsReducer {
    static func reduce(_ snapshot: AccessDiagnosticsSnapshot, event: AccessDiagnosticsEvent) -> AccessDiagnosticsSnapshot {
        var next = snapshot
        switch event {
        case .bootstrapFetching(_, let bootstrapHost, let fallbackHost):
            next.status = .bootstrapFetching
            next.appIDSummary = IMAPIContext.canonicalIOSAppID
            next.bootstrapHost = hostLabel(bootstrapHost)
            // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapFallbackHost = hostListLabel(fallbackHost)
            // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapCurrentHost = next.bootstrapHost
            next.bootstrapTier = "未命中"
            next.bootstrapState = "获取中"
            next.reason = "正在获取启动配置"
        case .bootstrapSucceeded(_, let bootstrapHost, let fallbackHost, let source):
            next.status = normalizedSource(source) == "live" ? .merchantResolving : .usingCache
            next.appIDSummary = IMAPIContext.canonicalIOSAppID
            next.bootstrapHost = hostLabel(bootstrapHost)
            // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapFallbackHost = hostListLabel(fallbackHost)
            // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapCurrentHost = next.bootstrapHost
            // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapTier = normalizedSource(source) == "live" ? "候选 1" : "缓存"
            // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapState = "成功"
            next.discoverySource = normalizedSource(source)
            next.reason = normalizedSource(source) == "live" ? "Bootstrap 可用" : "使用本地缓存"
        case .bootstrapFailed(_, let bootstrapHost, let fallbackHost, let reason):
            next.status = .failed
            next.appIDSummary = IMAPIContext.canonicalIOSAppID
            next.bootstrapHost = hostLabel(bootstrapHost)
            // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapFallbackHost = hostListLabel(fallbackHost)
            // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
            next.bootstrapCurrentHost = next.bootstrapHost
            next.bootstrapTier = "已阻断"
            next.bootstrapState = "失败"
            next.reason = sanitizedText(reason, fallback: "Bootstrap 失败")
        // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
        case .bootstrapRoute(let primaryHost, let fallbackHost, let currentHost, let tier, let source):
            next.bootstrapHost = endpointLabel(primaryHost)
            next.bootstrapFallbackHost = endpointListLabel(fallbackHost)
            next.bootstrapCurrentHost = endpointLabel(currentHost)
            next.bootstrapTier = normalizedSource(source) == "live"
                ? (tier == .backup ? "候选 N" : (tier == .failClosed ? "已阻断" : "候选 1"))
                : "缓存"
        // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
        case .merchantResolving(let name, let tenantAPIHost):
            next.status = .merchantResolving
            next.merchantName = sanitizedText(name, fallback: "待选择")
            next.tenantAPIHost = hostLabel(tenantAPIHost)
            next.merchantState = "获取中"
            next.reason = "正在获取商户数据面"
        case .merchantEntered(let name, let tenantAPIHost):
            next.status = .merchantDataPlane
            next.merchantName = sanitizedText(name, fallback: "当前商户")
            next.tenantAPIHost = hostLabel(tenantAPIHost)
            next.merchantState = "已进入"
            next.reason = "已进入商户数据面"
        case .discoveryFetching(let tenantAPIHost):
            next.status = .discoveryFetching
            next.tenantAPIHost = hostLabel(tenantAPIHost)
            next.discoverySource = "live"
            next.reason = "正在获取接入问路"
        case .discoveryResponse(let response, let tenantAPIHost):
            next.status = .endpointComparing
            next.tenantAPIHost = hostLabel(tenantAPIHost)
            next.discoverySource = normalizedDiscoverySource(response)
            let split = splitEndpoints(response)
            next.discoveryPrimaryHost = split.discoveryPrimary
            next.discoveryFallbackHost = split.discoveryFallback
            next.imPrimaryHost = split.imPrimary
            next.imFallbackHost = split.imFallback
            next.ipHintsCount = split.ipHintsCount
            next.ipStrategy = "按域名连接"
            next.ipPolicyNote = split.ipHintsCount > 0 ? "收到 IP hints，当前未直连 IP" : "未直连 IP"
            next.reason = "正在对比候选入口"
        case .discoveryOutcome(let outcome):
            switch outcome {
            case .network:
                next.discoverySource = "live"
                if next.status == .discoveryFetching {
                    next.status = .endpointComparing
                }
            case .memory:
                next.discoverySource = "cache"
                next.status = .usingCache
                next.reason = "使用内存缓存"
            case .cache:
                next.discoverySource = "last-good"
                next.status = .usingCache
                next.reason = "使用 last-good"
            case .unavailable:
                next.status = .failed
                next.reason = "接入问路不可用"
            }
        case .connectionComparing(let fallbackURL, let quicHost):
            next.status = .endpointComparing
            if next.imFallbackHost == "未配置" || next.imFallbackHost == "未获取" {
                next.imFallbackHost = hostLabel(fallbackURL?.host)
            }
            if let quicHost, !quicHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next.connectionProtocol = "QUIC"
                next.imCurrentHost = hostLabel(quicHost)
                next.reason = "QUIC 灰度候选，WSS 可兜底"
            } else {
                next.connectionProtocol = "WSS"
                next.imCurrentHost = hostLabel(fallbackURL?.host)
                next.reason = "正在对比实时入口"
            }
        case .connectionSelected(let currentHost, let protocolName, let reason):
            let existing = next.domainRoute(for: .imRealtime)
            let current = endpointLabel(currentHost)
            let selectedTier: IMRuntimeRouteTier = existing.backups.contains(current) ? .backup : .preferred
            next.status = selectedTier == .backup ? .selectedFallback : .selectedPrimary
            next.imCurrentHost = hostLabel(currentHost)
            next.connectionProtocol = protocolLabel(protocolName)
            next.reason = sanitizedText(reason, fallback: "主链路可用")
            next.routes[.imRealtime] = mergedRouteHit(
                existing: existing,
                endpoint: currentHost,
                tier: selectedTier
            )
        case .connectionFallback(let currentHost, let protocolName, let reason):
            next.status = .selectedFallback
            next.imCurrentHost = hostLabel(currentHost)
            next.connectionProtocol = protocolLabel(protocolName)
            next.reason = sanitizedText(reason, fallback: "已切到兜底")
            next.routes[.imRealtime] = mergedRouteHit(
                existing: next.domainRoute(for: .imRealtime),
                endpoint: currentHost,
                tier: .backup
            )
        case .runtimeRoutes(let snapshot):
            for service in IMRuntimeRouteService.allCases {
                guard let raw = snapshot.services[service.rawValue] else { continue }
                let primary = raw.preferred.compactMap(safeEndpointLabel)
                let backups = raw.backups.compactMap(safeEndpointLabel)
                let previous = next.routes[service]
                let current = previous?.current ?? "等待首次请求"
                next.routes[service] = AccessDiagnosticsDomainRoute(
                    current: current,
                    tier: previous?.tier ?? (current == "等待首次请求" ? "未命中" : "主域"),
                    primary: primary.first ?? "未配置",
                    backups: backups
                )
            }
        case .routeHit(let service, let endpoint, let tier):
            next.routes[service] = mergedRouteHit(
                existing: next.domainRoute(for: service),
                endpoint: endpoint,
                tier: tier
            )
        case .failed(let reason):
            next.status = .failed
            next.reason = sanitizedText(reason, fallback: "接入失败")
        }
        return next
    }

    static func sanitizedText(_ value: String, fallback: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return fallback }
        let sensitivePattern = #"(?i)(token|entry_ticket|authorization|signature|secret|password|key|credential)"#
        if singleLine.range(of: sensitivePattern, options: .regularExpression) != nil {
            return fallback
        }
        if singleLine.count > 18 {
            return "\(singleLine.prefix(16))..."
        }
        return singleLine
    }

    static func hostLabel(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "未配置" }
        if let url = URL(string: raw), let host = url.host {
            return sanitizedHost(host)
        }
        return sanitizedHost(raw)
    }

    // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
    static func hostListLabel(_ value: String?) -> String {
        listLabel(value, transform: hostLabel)
    }
    // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

    static func endpointLabel(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "未配置" }
        let parsed = URL(string: raw.contains("://") ? raw : "https://\(raw)")
        guard let url = parsed,
              url.user == nil,
              url.password == nil,
              let host = url.host else { return "未配置" }
        let scheme = (url.scheme ?? "https").lowercased()
        guard ["https", "http", "wss", "ws", "quic"].contains(scheme) else { return "未配置" }
        let defaultPort = ["https", "wss", "quic"].contains(scheme) ? 443 : 80
        return url.port.map { $0 == defaultPort ? sanitizedHost(host) : "\(sanitizedHost(host)):\($0)" }
            ?? sanitizedHost(host)
    }

    // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
    static func endpointListLabel(_ value: String?) -> String {
        listLabel(value, transform: endpointLabel)
    }

    private static func listLabel(_ value: String?, transform: (String?) -> String) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "未配置" }
        let labels = raw
            .split(whereSeparator: { ["、", ",", ";"].contains(String($0)) })
            .map { transform(String($0)) }
            .filter { $0 != "未配置" }
        return labels.isEmpty ? "未配置" : labels.joined(separator: "、")
    }
    // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

    private static func safeEndpointLabel(_ value: String) -> String? {
        let label = endpointLabel(value)
        return label == "未配置" ? nil : label
    }

    private static func mergedRouteHit(
        existing: AccessDiagnosticsDomainRoute,
        endpoint: String,
        tier: IMRuntimeRouteTier
    ) -> AccessDiagnosticsDomainRoute {
        let current = endpointLabel(endpoint)
        return AccessDiagnosticsDomainRoute(
            current: current,
            tier: tier == .backup ? "备用域" : (tier == .failClosed ? "已阻断" : "主域"),
            primary: existing.primary,
            backups: existing.backups
        )
    }

    private static func sanitizedHost(_ value: String) -> String {
        let host = value
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !host.isEmpty else { return "未配置" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        let cleaned = String(host.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).isEmpty ? "未配置" : cleaned
    }

    private static func protocolLabel(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "QUIC" { return "QUIC" }
        return "WSS"
    }

    private static func normalizedSource(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["cache", "memory"].contains(normalized) { return "cache" }
        if ["last-good", "last_good", "lastgood", "stale"].contains(normalized) { return "last-good" }
        return "live"
    }

    private static func normalizedDiscoverySource(_ response: RemoteAccessDiscoveryResponse) -> String {
        if response.stale { return "last-good" }
        return normalizedSource(response.source)
    }

    private static func splitEndpoints(_ response: RemoteAccessDiscoveryResponse) -> (
        discoveryPrimary: String,
        discoveryFallback: String,
        imPrimary: String,
        imFallback: String,
        ipHintsCount: Int
    ) {
        let endpoints = response.endpoints
        let discoveryCandidates = endpoints
            .filter { isDiscoveryEndpoint($0) }
            .sorted(by: endpointPrecedes)
        let imCandidates = endpoints
            .filter { $0.usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "im_realtime" }
            .sorted(by: endpointPrecedes)
        let fallbackCandidates = response.discoveryFallbacks.sorted(by: endpointPrecedes)
        let imPrimary = imCandidates.first
        let imFallback = imCandidates.dropFirst().first(where: { $0.normalizedNetwork == "direct" })
            ?? imCandidates.dropFirst().first
        let discoveryPrimary = discoveryCandidates.first
        let discoveryFallback = fallbackCandidates.first
            ?? discoveryCandidates.dropFirst().first

        let ipHints = Set((endpoints + response.discoveryFallbacks).flatMap(\.resolvedIPs).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })

        return (
            hostLabel(discoveryPrimary?.host),
            hostLabel(discoveryFallback?.host),
            hostLabel(imPrimary?.host),
            hostLabel(imFallback?.host),
            ipHints.count
        )
    }

    private static func isDiscoveryEndpoint(_ endpoint: RemoteAccessDiscoveryEndpoint) -> Bool {
        let usage = endpoint.usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return usage.contains("discovery")
            || usage.contains("connect")
            || usage.contains("access")
            || usage.contains("tenant_api")
            || usage == "api"
    }

    private static func endpointPrecedes(_ lhs: RemoteAccessDiscoveryEndpoint, _ rhs: RemoteAccessDiscoveryEndpoint) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.normalizedID < rhs.normalizedID
    }
}

@MainActor
struct AccessDiagnosticsPolicy: Equatable {
    let appID: String
    let overlayConfiguration: AccessDiagnosticsOverlayConfiguration
    let copyEnabled: Bool

    static let disabled = AccessDiagnosticsPolicy(
        appID: "",
        overlayConfiguration: .unavailable,
        copyEnabled: false
    )

    init(
        appID: String = IMAPIContext.canonicalIOSAppID,
        overlayConfiguration: AccessDiagnosticsOverlayConfiguration? = nil,
        overlayEnabled: Bool? = nil,
        copyEnabled: Bool
    ) {
        self.appID = appID
        self.overlayConfiguration = overlayConfiguration
            ?? AccessDiagnosticsOverlayConfiguration(
                configuredValue: overlayEnabled,
                fieldWasPresent: overlayEnabled != nil
            )
        self.copyEnabled = copyEnabled
    }

    var allowsOverlay: Bool {
        overlayConfiguration.isEnabled
            && !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
enum AccessDiagnosticsAuthorization: Equatable {
    case unavailable
    case disabled
    case enabled(appID: String)

    func allows(_ appID: String?) -> Bool {
        guard case .enabled(let authorizedAppID) = self else { return false }
        let normalizedAuthorizedAppID = Self.normalizedRequiredAppID(authorizedAppID)
        let normalizedAppID = Self.normalizedRequiredAppID(appID ?? "")
        return !normalizedAuthorizedAppID.isEmpty && normalizedAuthorizedAppID == normalizedAppID
    }

    fileprivate static func normalizedRequiredAppID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return IMAPIContext.normalizedIOSAppID(trimmed, allowCustomAppID: true)
    }
}

enum AccessDiagnosticsAuthPhase: String, Equatable, Hashable {
    case loggedOut
    case authenticated
}

struct AccessDiagnosticsActivationScope: Equatable, Hashable {
    let appID: String
    let accountID: String?
    let tenantID: String?
    let authPhase: AccessDiagnosticsAuthPhase
    let sessionGeneration: Int64
    let deviceID: String?
    let sessionEpoch: String?

    init(
        appID: String,
        accountID: String? = nil,
        tenantID: String? = nil,
        authPhase: AccessDiagnosticsAuthPhase,
        sessionGeneration: Int64 = 0,
        deviceID: String? = nil,
        sessionEpoch: String? = nil
    ) {
        let trimmedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = trimmedAppID.isEmpty
            ? ""
            : IMAPIContext.normalizedIOSAppID(trimmedAppID, allowCustomAppID: true)
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTenantID = tenantID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = authPhase == .authenticated && normalizedAccountID?.isEmpty == false
            ? normalizedAccountID
            : nil
        self.tenantID = authPhase == .authenticated && normalizedTenantID?.isEmpty == false
            ? normalizedTenantID
            : nil
        self.authPhase = authPhase
        self.sessionGeneration = authPhase == .authenticated ? max(0, sessionGeneration) : 0
        // The session generation alone does not change on every device or epoch transition.
        self.deviceID = authPhase == .authenticated ? deviceID : nil
        self.sessionEpoch = authPhase == .authenticated ? sessionEpoch : nil
    }

    var isValid: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (authPhase == .loggedOut || (accountID?.isEmpty == false && tenantID?.isEmpty == false))
    }
}

enum AccessDiagnosticsActivationEntry: Equatable {
    case loggedOutLoginLogo
    case loggedInAboutLogo
}

enum AccessDiagnosticsVisibilityTransition: Equatable {
    case unchanged
    case opened
    case closed
}

private struct AccessDiagnosticsTapSequence {
    var entry: AccessDiagnosticsActivationEntry?
    var scope: AccessDiagnosticsActivationScope?
    var timestamps: [UInt64] = []

    mutating func reset() {
        entry = nil
        scope = nil
        timestamps.removeAll(keepingCapacity: true)
    }
}
// JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

@MainActor
final class AccessDiagnostics: ObservableObject {
    static let shared = AccessDiagnostics()
    static var isOverlayCompiled: Bool {
        true
    }

    @Published private(set) var snapshot: AccessDiagnosticsSnapshot
    @Published private(set) var isVisible: Bool
    @Published private(set) var isCopyEnabled: Bool
    private var lastAppliedPolicy: AccessDiagnosticsPolicy = .disabled
    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private static let manualTapThreshold = 5
    private static let manualTapWindowNanoseconds: UInt64 = 3_000_000_000
    private var authorization: AccessDiagnosticsAuthorization = .unavailable
    private var currentScope: AccessDiagnosticsActivationScope?
    private(set) var connectionScopeEpoch: UInt64 = 0
    private var lastConnectionResult: RealtimeConnectionDiagnostic?
    private var turnHosts: [String] = []
    private var turnCallID: String?
    private var turnLookupTask: Task<Void, Never>?
    private var turnTimeoutTask: Task<Void, Never>?
    private var manuallyActivatedScope: AccessDiagnosticsActivationScope?
    private var tapSequence = AccessDiagnosticsTapSequence()
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    init(snapshot: AccessDiagnosticsSnapshot = .initial) {
        self.snapshot = snapshot
        self.isVisible = false
        self.isCopyEnabled = false
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    func updateScope(_ scope: AccessDiagnosticsActivationScope?) {
        let nextScope = scope?.isValid == true ? scope : nil
        guard nextScope != currentScope else { return }
        currentScope = nextScope
        turnHosts = []
        turnCallID = nil
        connectionScopeEpoch &+= 1
        lastConnectionResult = nil
        manuallyActivatedScope = nil
        resetTapSequence()
        clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
        recomputeVisibility()
    }

    func applyPolicy(_ policy: AccessDiagnosticsPolicy) {
        lastAppliedPolicy = policy
        let normalizedAppID = AccessDiagnosticsAuthorization.normalizedRequiredAppID(policy.appID)
        if Self.isOverlayCompiled, policy.overlayConfiguration.isEnabled, !normalizedAppID.isEmpty {
            authorization = .enabled(appID: normalizedAppID)
        } else {
            authorization = policy.overlayConfiguration == .disabled ? .disabled : .unavailable
        }
        if !authorization.allows(currentScope?.appID) {
            turnHosts = []
            turnCallID = nil
            manuallyActivatedScope = nil
            resetTapSequence()
            clearSnapshot(overlayStatus: policy.overlayConfiguration.displayText)
        } else {
            snapshot.currentPolicyOverlayStatus = policy.overlayConfiguration.displayText
        }
        recomputeVisibility()
    }

    func bindConnectionDiagnostics(to client: RealtimeClient) {
        client.diagnosticScopeProvider = { [weak self] in self?.connectionScopeEpoch }
        client.onDiagnostic = { [weak self] event, scopeEpoch in
            self?.recordConnection(event, scopeEpoch: scopeEpoch)
        }
    }

    /// The local epoch is memory-only and never enters the diagnostic record or log.
    func recordConnection(_ event: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        guard event.currentAtReceipt,
              let scopeEpoch, scopeEpoch == connectionScopeEpoch else { return }
        if let previous = lastConnectionResult {
            guard event.generation >= previous.generation else { return }
            // Keep one record: the first failure in this generation, otherwise the latest result.
            // A new generation or scope replaces it; old late callbacks never overwrite it.
            if event.generation == previous.generation, previous.isFailure { return }
        }
        lastConnectionResult = event
        if isVisible { snapshot.connectionResult = event }
    }

    func record(_ event: AccessDiagnosticsEvent) {
        guard isVisible else { return }
        snapshot = AccessDiagnosticsReducer.reduce(snapshot, event: event)
    }

    // Only sanitized hosts are retained; ICE credentials and URLs never enter the snapshot.
    func recordTurnServers(urls: [String], callID: String? = nil) {
        guard let scope = currentScope, authorization.allows(scope.appID) else { return }
        let hosts = AccessDiagnosticsTurnAddresses.hosts(from: urls)
        guard hosts != turnHosts || callID != turnCallID else { return }
        turnHosts = hosts
        turnCallID = callID
        refreshTurnAddresses()
    }

    func clearTurnServers(callID: String?) {
        guard callID == turnCallID else { return }
        turnHosts = []
        turnCallID = nil
        refreshTurnAddresses()
    }

    private func refreshTurnAddresses() {
        turnLookupTask?.cancel()
        turnTimeoutTask?.cancel()
        snapshot.turnAddresses.begin(hosts: isVisible ? turnHosts : [])
        guard isVisible, !turnHosts.isEmpty else { return }
        let hosts = turnHosts
        let generation = snapshot.turnAddresses.generation
        turnLookupTask = Task { [weak self] in
            for host in hosts {
                guard !Task.isCancelled else { return }
                let ips = await AccessDiagnosticsTurnAddresses.resolve(host)
                guard !Task.isCancelled, let self, self.isVisible else { return }
                self.snapshot.turnAddresses.apply(ips, host: host, generation: generation)
            }
        }
        turnTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.isVisible, self.snapshot.turnAddresses.generation == generation else { return }
            self.turnLookupTask?.cancel()
            for host in hosts { self.snapshot.turnAddresses.apply([], host: host, generation: generation) }
        }
    }

    func disablePreservingAllowedPolicy(reason: String = "接入诊断暂不可用") {
        resetTapSequence()
        guard Self.isOverlayCompiled,
              lastAppliedPolicy.allowsOverlay,
              let scope = currentScope,
              authorization.allows(scope.appID) else {
            forceDisable()
            return
        }
        isCopyEnabled = false
        // A transient auth failure is not a policy revocation. Keep the
        // same-AppId authorization even before the user opens the overlay,
        // otherwise the next five taps can never pass the activation guard.
        guard isVisible, manuallyActivatedScope == scope else {
            manuallyActivatedScope = nil
            clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
            recomputeVisibility()
            return
        }
        snapshot = AccessDiagnosticsReducer.reduce(snapshot, event: .failed(reason: reason))
        snapshot.currentPolicyOverlayStatus = lastAppliedPolicy.overlayConfiguration.displayText
    }

    func forceDisable() {
        turnHosts = []
        turnCallID = nil
        lastConnectionResult = nil
        lastAppliedPolicy = .disabled
        authorization = .unavailable
        manuallyActivatedScope = nil
        resetTapSequence()
        clearSnapshot()
        recomputeVisibility()
    }

    func reset(to snapshot: AccessDiagnosticsSnapshot = .initial) {
        turnHosts = []
        turnCallID = nil
        turnLookupTask?.cancel()
        turnTimeoutTask?.cancel()
        self.snapshot = snapshot
        lastConnectionResult = snapshot.connectionResult
    }

    @discardableResult
    func registerLogoTap(
        entry: AccessDiagnosticsActivationEntry,
        scope: AccessDiagnosticsActivationScope,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AccessDiagnosticsVisibilityTransition {
        guard scope.isValid,
              currentEntryIsAllowed(entry, scope: scope),
              authorization.allows(scope.appID),
              currentScope == scope else {
            resetTapSequence()
            return .unchanged
        }

        if tapSequence.entry != entry || tapSequence.scope != scope {
            resetTapSequence()
            tapSequence.entry = entry
            tapSequence.scope = scope
        }

        tapSequence.timestamps.removeAll { timestamp in
            nowNanoseconds < timestamp || nowNanoseconds - timestamp > Self.manualTapWindowNanoseconds
        }
        tapSequence.timestamps.append(nowNanoseconds)

        guard tapSequence.timestamps.count >= Self.manualTapThreshold,
              let firstTap = tapSequence.timestamps.suffix(Self.manualTapThreshold).first,
              nowNanoseconds >= firstTap,
              nowNanoseconds - firstTap <= Self.manualTapWindowNanoseconds else {
            return .unchanged
        }

        resetTapSequence()
        return toggleManualActivation(for: scope)
    }

    func resetLogoTapSequence(entry: AccessDiagnosticsActivationEntry? = nil) {
        guard entry == nil || tapSequence.entry == entry else { return }
        resetTapSequence()
    }

    private func toggleManualActivation(for scope: AccessDiagnosticsActivationScope) -> AccessDiagnosticsVisibilityTransition {
        if isVisible, manuallyActivatedScope == scope {
            manuallyActivatedScope = nil
            clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
            recomputeVisibility()
            return .closed
        }
        manuallyActivatedScope = scope
        clearSnapshot(overlayStatus: lastAppliedPolicy.overlayConfiguration.displayText)
        recomputeVisibility()
        return isVisible ? .opened : .unchanged
    }

    private func currentEntryIsAllowed(
        _ entry: AccessDiagnosticsActivationEntry,
        scope: AccessDiagnosticsActivationScope
    ) -> Bool {
        switch (entry, scope.authPhase) {
        case (.loggedOutLoginLogo, .loggedOut),
             (.loggedInAboutLogo, .authenticated):
            return true
        default:
            return false
        }
    }

    private func resetTapSequence() {
        tapSequence.reset()
    }

    private func clearSnapshot(overlayStatus: String? = nil) {
        turnLookupTask?.cancel()
        turnTimeoutTask?.cancel()
        snapshot = .initial
        if let overlayStatus {
            snapshot.currentPolicyOverlayStatus = overlayStatus
        }
    }

    private func recomputeVisibility() {
        let shouldShow = Self.isOverlayCompiled
            && currentScope.map { authorization.allows($0.appID) && manuallyActivatedScope == $0 } == true
        let wasVisible = isVisible
        isVisible = shouldShow
        if shouldShow && !wasVisible { refreshTurnAddresses() }
        if shouldShow { snapshot.connectionResult = lastConnectionResult }
        isCopyEnabled = false
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
}

private let accessDiagnosticsOverlayBinaryMarker =
    "WXT_ACCESS_DIAGNOSTICS_OVERLAY_BINARY_MARKER_V1"

struct AccessDebugOverlay: View {
    @ObservedObject private var diagnostics: AccessDiagnostics
    let onTap: () -> Void

    init(
        diagnostics: AccessDiagnostics = .shared,
        onTap: @escaping () -> Void
    ) {
        self.diagnostics = diagnostics
        self.onTap = onTap
    }

    var body: some View {
        capsuleContent
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(capsuleBackground)
            .overlay(capsuleBorder)
            .contentShape(Capsule())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(accessDiagnosticsOverlayBinaryMarker)
            .accessibilityLabel(Text("接入诊断"))
            .accessibilityValue(Text(diagnostics.snapshot.compactText))
            .accessibilityAction {
                onTap()
            }
    }

    private var capsuleContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(diagnostics.snapshot.compactText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white)
    }

    private var capsuleBackground: some View {
        Capsule().fill(Color.black.opacity(0.58))
    }

    private var capsuleBorder: some View {
        Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
    }

    private var statusColor: Color {
        switch diagnostics.snapshot.status {
        case .failed:
            return .red
        case .selectedFallback, .usingCache:
            return .yellow
        case .selectedPrimary, .merchantDataPlane:
            return .green
        default:
            return .cyan
        }
    }
}

#if targetEnvironment(simulator)
enum SimulatorAccessEnvironment: String, CaseIterable {
    case local
    case production

    static let modeKey = "im2.simulator.accessEnvironment"
    private static let platformBaseKey = "im2.api.platformBase"
    private static let tenantBaseKey = "im2.api.tenantBase"
    private static let imBaseKey = "im2.api.imBase"
    private static let rtcBaseKey = "im2.api.rtcBase"
    private static let bootstrapBaseKey = "im2.api.bootstrapBase"
    private static let localBase = "http://127.0.0.1:5174"
	private static var productionBootstrapBase: String {
		guard case .configured(let configuration) = IMAppBootstrapHostConfigurationLoader.load(
			info: Bundle.main.infoDictionary ?? [:],
			appID: IMAPIContext.canonicalIOSAppID
		) else { return "" }
		return configuration.primary.absoluteString
	}
    private static let defaultEnvironment: SimulatorAccessEnvironment = .production
    private static let runtimeBaseOverrideKeys = [
        platformBaseKey,
        tenantBaseKey,
        imBaseKey,
        rtcBaseKey
    ]

    var title: String {
        switch self {
        case .local: return "本地"
        case .production: return "生产"
        }
    }

    var subtitle: String {
        switch self {
        case .local: return "127.0.0.1:5174"
        case .production: return "应用专属接入域名"
        }
    }

    static func ensureDefaultSelection(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: modeKey).flatMap(SimulatorAccessEnvironment.init(rawValue:))
        let selected = stored ?? defaultEnvironment
        write(selected, defaults: defaults)
        if stored == nil {
            clearRuntimeState(defaults: defaults)
        }
        defaults.synchronize()
    }

    static func current(defaults: UserDefaults = .standard) -> SimulatorAccessEnvironment {
        if let raw = defaults.string(forKey: modeKey),
           let environment = SimulatorAccessEnvironment(rawValue: raw) {
            return environment
        }
        return defaultEnvironment
    }

    @discardableResult
    static func apply(_ environment: SimulatorAccessEnvironment, defaults: UserDefaults = .standard) -> Bool {
        let previous = current(defaults: defaults)
        write(environment, defaults: defaults)
        if previous != environment {
            clearRuntimeState(defaults: defaults)
        }
        defaults.synchronize()
        return previous != environment
    }

    static func currentSummary(defaults: UserDefaults = .standard) -> String {
        current(defaults: defaults).subtitle
    }

    private static func write(_ environment: SimulatorAccessEnvironment, defaults: UserDefaults) {
        defaults.set(environment.rawValue, forKey: modeKey)
        switch environment {
        case .local:
            for key in runtimeBaseOverrideKeys {
                defaults.set(localBase, forKey: key)
            }
            defaults.set(localBase, forKey: bootstrapBaseKey)
        case .production:
            for key in runtimeBaseOverrideKeys {
                defaults.removeObject(forKey: key)
            }
			if productionBootstrapBase.isEmpty { defaults.removeObject(forKey: bootstrapBaseKey) }
			else { defaults.set(productionBootstrapBase, forKey: bootstrapBaseKey) }
        }
    }

    private static func clearRuntimeState(defaults: UserDefaults) {
        IMAppBootstrapLastGoodStore.clearAll(defaults: defaults)
        IMAppPolicyLastGoodStore.clearAll(defaults: defaults)
        IMTenantIMTokenExpiryStore.clear(defaults: defaults)
        AccessDiscoveryStore.clearDefaultStore()
        IMAPIContext.clearStoredSession()
    }
}

#endif

private struct AccessDebugOverlayPanel: View {
    @ObservedObject var diagnostics: AccessDiagnostics
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: estimatedPanelHeight > maxHeight) {
            expandedPanel
        }
        .frame(
            width: 252,
            height: min(estimatedPanelHeight, maxHeight),
            alignment: .topLeading
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.52)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("接入诊断")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }

            ForEach(Array(diagnosticGroups.enumerated()), id: \.offset) { _, group in
                diagnosticSection(group.title, rows: group.rows)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 252, alignment: .leading)
    }

    private var diagnosticGroups: [(title: String, rows: [(String, String)])] {
        [("客户端", diagnostics.snapshot.clientIdentityRows),
         ("最近连接结果", diagnostics.snapshot.connectionRows),
         ("TURN地址", diagnostics.snapshot.turnAddresses.rows)] + diagnostics.snapshot.domainSections
    }

    private var estimatedPanelHeight: CGFloat {
        let rowCount = diagnosticGroups.reduce(0) { $0 + $1.rows.count }
        let wrappedRowExtraLines = diagnosticGroups
            .flatMap(\.rows)
            .reduce(0) { $0 + max(0, estimatedLineCount($1.1) - 1) }
        let verticalPadding: CGFloat = 24
        let headerHeight: CGFloat = 17
        let outerSpacing: CGFloat = CGFloat(diagnosticGroups.count) * 10
        let sectionTitleHeights: CGFloat = CGFloat(diagnosticGroups.count) * 14
        let rowHeights: CGFloat = CGFloat(rowCount) * 14
        let rowSpacing: CGFloat = CGFloat(rowCount) * 4
        let wrappedRowExtra: CGFloat = CGFloat(wrappedRowExtraLines) * 14
        return verticalPadding + headerHeight + outerSpacing + sectionTitleHeights + rowHeights + rowSpacing + wrappedRowExtra
    }

    private func estimatedLineCount(_ value: String) -> Int {
        let weightedLength = value.reduce(0) { partial, character in
            let isASCII = character.unicodeScalars.allSatisfy { $0.value < 128 }
            return partial + (isASCII ? 1 : 2)
        }
        return min(4, max(1, Int(ceil(Double(weightedLength) / 34.0))))
    }

    private func diagnosticSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(row.0)：")
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 72, alignment: .leading)
                    Text(row.1)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(row.0): \(row.1)"))
            }
        }
    }
}
enum AccessDebugOverlayExpansionDirection: Equatable {
    case up
    case down
}

enum AccessDebugOverlayHorizontalAlignment: Equatable {
    case leading
    case trailing
}

struct AccessDebugOverlayHost: View {
    @ObservedObject private var diagnostics: AccessDiagnostics
    let safeAreaInsets: EdgeInsets

    @State private var basePosition: CGPoint?
    @State private var capsuleSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero
    @State private var isDragging = false
    @State private var isExpanded = false
    @State private var suppressTapAfterDrag = false
    @State private var releaseImpulse: CGSize = .zero
    @State private var autoParkGeneration = 0
    @GestureState private var dragTranslation: CGSize = .zero

    init(diagnostics: AccessDiagnostics = .shared, safeAreaInsets: EdgeInsets) {
        self.diagnostics = diagnostics
        self.safeAreaInsets = safeAreaInsets
    }

    var body: some View {
        GeometryReader { proxy in
            let measuredCapsuleSize = effectiveCapsuleSize
            let dragBounds = AccessDebugOverlayDragBounds(
                containerSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                overlaySize: measuredCapsuleSize
            )
            let restingPosition = basePosition ?? dragBounds.defaultPosition
            let displayedPosition = dragBounds.clamp(
                CGPoint(
                    x: restingPosition.x + dragTranslation.width,
                    y: restingPosition.y + dragTranslation.height
                )
            )
            let panelLayout = AccessDebugOverlayPanelLayout(
                containerSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                capsulePosition: displayedPosition,
                capsuleSize: measuredCapsuleSize,
                panelSize: effectivePanelSize(maxHeight: proxy.size.height)
            )
            let capsuleHitFrame = CGRect(
                x: displayedPosition.x - measuredCapsuleSize.width / 2,
                y: displayedPosition.y - measuredCapsuleSize.height / 2,
                width: measuredCapsuleSize.width,
                height: measuredCapsuleSize.height
            )

            ZStack {
                if isExpanded {
                    AccessDebugOverlayPanel(
                        diagnostics: diagnostics,
                        maxHeight: panelLayout.panelMaxHeight
                    )
                    .background(
                        GeometryReader { sizeProxy in
                            Color.clear.preference(
                                key: AccessDebugOverlayPanelSizePreferenceKey.self,
                                value: sizeProxy.size
                            )
                        }
                    )
                    .position(panelLayout.panelPosition)
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.97, anchor: panelLayout.transitionAnchor)
                        )
                    )
                    .zIndex(0)
                }

                AccessDebugOverlay(
                    diagnostics: diagnostics,
                    onTap: { toggleExpandedFromTap(bounds: dragBounds) }
                )
                .fixedSize()
                .background(
                    GeometryReader { sizeProxy in
                        Color.clear.preference(
                            key: AccessDebugOverlayCapsuleSizePreferenceKey.self,
                            value: sizeProxy.size
                        )
                    }
                )
                .contentShape(Rectangle())
                .modifier(
                    AccessDebugOverlayDragDeformation(
                        translation: deformationTranslation,
                        isDragging: isDragging
                    )
                )
                .position(displayedPosition)
                .gesture(dragGesture(bounds: dragBounds, restingPosition: restingPosition))
                .zIndex(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(
                AccessDebugOverlayHitShape(
                    capsuleFrame: capsuleHitFrame,
                    panelFrame: isExpanded ? panelLayout.panelFrame : nil
                )
            )
            .animation(.spring(response: 0.26, dampingFraction: 0.88), value: isExpanded)
            .onAppear {
                basePosition = dragBounds.clamp(restingPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onChangeCompat(of: proxy.size) { _, _ in
                basePosition = dragBounds.clamp(basePosition ?? dragBounds.defaultPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onChangeCompat(of: safeAreaInsets.top) { _, _ in
                basePosition = dragBounds.clamp(basePosition ?? dragBounds.defaultPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onChangeCompat(of: safeAreaInsets.bottom) { _, _ in
                basePosition = dragBounds.clamp(basePosition ?? dragBounds.defaultPosition)
                scheduleAutoPark(bounds: dragBounds)
            }
            .onPreferenceChange(AccessDebugOverlayCapsuleSizePreferenceKey.self) { newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                guard !accessDebugOverlaySizeApproximatelyEqual(capsuleSize, newSize) else { return }
                capsuleSize = newSize
                let updatedBounds = AccessDebugOverlayDragBounds(
                    containerSize: proxy.size,
                    safeAreaInsets: safeAreaInsets,
                    overlaySize: newSize
                )
                basePosition = updatedBounds.clamp(basePosition ?? updatedBounds.defaultPosition)
                scheduleAutoPark(bounds: updatedBounds)
            }
            .onPreferenceChange(AccessDebugOverlayPanelSizePreferenceKey.self) { newSize in
                guard newSize.width > 0, newSize.height > 0 else { return }
                guard !accessDebugOverlaySizeApproximatelyEqual(panelSize, newSize) else { return }
                panelSize = newSize
            }
        }
    }

    private var effectiveCapsuleSize: CGSize {
        guard capsuleSize.width > 0, capsuleSize.height > 0 else {
            return CGSize(width: 132, height: 32)
        }
        return capsuleSize
    }

    private func effectivePanelSize(maxHeight: CGFloat) -> CGSize {
        guard panelSize.width > 0, panelSize.height > 0 else {
            return CGSize(width: 252, height: min(maxHeight, 300))
        }
        return panelSize
    }

    private var deformationTranslation: CGSize {
        CGSize(
            width: dragTranslation.width + releaseImpulse.width,
            height: dragTranslation.height + releaseImpulse.height
        )
    }

    private func dragGesture(bounds: AccessDebugOverlayDragBounds, restingPosition: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                let proposed = CGPoint(
                    x: restingPosition.x + value.translation.width,
                    y: restingPosition.y + value.translation.height
                )
                let clamped = bounds.clamp(proposed)
                state = CGSize(
                    width: clamped.x - restingPosition.x,
                    height: clamped.y - restingPosition.y
                )
            }
            .onChanged { _ in
                if !isDragging {
                    cancelAutoPark()
                    suppressTapAfterDrag = true
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.78)) {
                        isExpanded = false
                        isDragging = true
                        releaseImpulse = .zero
                    }
                }
            }
            .onEnded { value in
                let proposed = CGPoint(
                    x: restingPosition.x + value.translation.width,
                    y: restingPosition.y + value.translation.height
                )
                let clamped = bounds.clamp(proposed)
                let settle = AccessDebugOverlayDragRelease.settledPosition(
                    restingPosition: restingPosition,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    bounds: bounds
                )
                let impulse = CGSize(width: settle.x - clamped.x, height: settle.y - clamped.y)

                withAnimation(.interpolatingSpring(stiffness: 290, damping: 26)) {
                    basePosition = settle
                    isDragging = false
                    releaseImpulse = impulse
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.interpolatingSpring(stiffness: 260, damping: 20)) {
                        releaseImpulse = .zero
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    suppressTapAfterDrag = false
                    scheduleAutoPark(bounds: bounds)
                }
            }
    }

    private func toggleExpandedFromTap(bounds: AccessDebugOverlayDragBounds) {
        guard !isDragging, !suppressTapAfterDrag else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isExpanded.toggle()
        }
        if isExpanded {
            cancelAutoPark()
        } else {
            scheduleAutoPark(bounds: bounds)
        }
    }

    private func scheduleAutoPark(bounds: AccessDebugOverlayDragBounds) {
        guard !isExpanded, !isDragging else { return }
        autoParkGeneration += 1
        let generation = autoParkGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + AccessDebugOverlayAutoPark.idleDelay) {
            guard generation == autoParkGeneration, !isExpanded, !isDragging else { return }
            let target = AccessDebugOverlayAutoPark.parkedPosition(bounds: bounds)
            guard basePosition != nil else {
                basePosition = target
                return
            }
            withAnimation(.interpolatingSpring(stiffness: 260, damping: 28)) {
                basePosition = target
            }
        }
    }

    private func cancelAutoPark() {
        autoParkGeneration += 1
    }
}

private struct AccessDebugOverlayHitShape: Shape {
    let capsuleFrame: CGRect
    let panelFrame: CGRect?
    private static let capsuleHitPadding: CGFloat = 3
    private static let panelHitPadding: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: capsuleFrame.insetBy(dx: -Self.capsuleHitPadding, dy: -Self.capsuleHitPadding),
            cornerSize: CGSize(
                width: capsuleFrame.height / 2 + Self.capsuleHitPadding,
                height: capsuleFrame.height / 2 + Self.capsuleHitPadding
            )
        )
        if let panelFrame {
            path.addRoundedRect(
                in: panelFrame.insetBy(dx: -Self.panelHitPadding, dy: -Self.panelHitPadding),
                cornerSize: CGSize(width: 14, height: 14)
            )
        }
        return path
    }
}

enum AccessDebugOverlayAutoPark {
    static let idleDelay: TimeInterval = 1.8

    static func parkedPosition(bounds: AccessDebugOverlayDragBounds) -> CGPoint {
        bounds.defaultPosition
    }
}

struct AccessDebugOverlayDragRelease {
    static let inertiaMultiplier: CGFloat = 0.26
    static let maxInertiaDistance: CGFloat = 34

    static func settledPosition(
        restingPosition: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        bounds: AccessDebugOverlayDragBounds
    ) -> CGPoint {
        let current = bounds.clamp(
            CGPoint(
                x: restingPosition.x + translation.width,
                y: restingPosition.y + translation.height
            )
        )
        let predicted = bounds.clamp(
            CGPoint(
                x: restingPosition.x + predictedEndTranslation.width,
                y: restingPosition.y + predictedEndTranslation.height
            )
        )
        let impulse = CGSize(
            width: clamp((predicted.x - current.x) * inertiaMultiplier, maxDistance: maxInertiaDistance),
            height: clamp((predicted.y - current.y) * inertiaMultiplier, maxDistance: maxInertiaDistance)
        )
        return bounds.clamp(
            CGPoint(
                x: current.x + impulse.width,
                y: current.y + impulse.height
            )
        )
    }

    private static func clamp(_ value: CGFloat, maxDistance: CGFloat) -> CGFloat {
        min(max(value, -maxDistance), maxDistance)
    }
}

struct AccessDebugOverlayDragBounds: Equatable {
    static let horizontalMargin: CGFloat = 10
    // Keep the floating diagnostics surface below the navigation toolbar. The
    // toolbar owns group-title and trailing more-action hit targets, so neither
    // the capsule nor its expanded panel may enter this reserved strip.
    static let topNavigationControlReserve: CGFloat = 52
    static let bottomNavigationReserve: CGFloat = 58
    static let bottomMargin: CGFloat = 10

    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let overlaySize: CGSize

    var defaultPosition: CGPoint {
        CGPoint(x: maxX, y: minY)
    }

    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private var minX: CGFloat {
        Self.horizontalMargin + overlaySize.width / 2
    }

    private var maxX: CGFloat {
        max(minX, containerSize.width - Self.horizontalMargin - overlaySize.width / 2)
    }

    private var minY: CGFloat {
        max(safeAreaInsets.top + Self.topNavigationControlReserve, 12) + overlaySize.height / 2
    }

    private var maxY: CGFloat {
        let reservedBottom = max(safeAreaInsets.bottom + Self.bottomNavigationReserve, 72)
        let rawMax = containerSize.height - reservedBottom - Self.bottomMargin - overlaySize.height / 2
        return max(minY, rawMax)
    }
}

struct AccessDebugOverlayPanelLayout: Equatable {
    static let spacing: CGFloat = 8

    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let capsulePosition: CGPoint
    let capsuleSize: CGSize
    let panelSize: CGSize

    var panelMaxHeight: CGFloat {
        max(1, bottomLimit - topLimit)
    }

    var expansionDirection: AccessDebugOverlayExpansionDirection {
        if availableBelow >= panelSize.height { return .down }
        if availableAbove >= panelSize.height { return .up }
        return availableBelow >= availableAbove ? .down : .up
    }

    var horizontalAlignment: AccessDebugOverlayHorizontalAlignment {
        capsulePosition.x < containerSize.width * 0.5 ? .leading : .trailing
    }

    var transitionAnchor: UnitPoint {
        switch (expansionDirection, horizontalAlignment) {
        case (.up, .leading):
            return .bottomLeading
        case (.up, .trailing):
            return .bottomTrailing
        case (.down, .leading):
            return .topLeading
        case (.down, .trailing):
            return .topTrailing
        }
    }

    var panelPosition: CGPoint {
        CGPoint(
            x: clamp(desiredPanelCenterX, min: panelSize.width / 2 + AccessDebugOverlayDragBounds.horizontalMargin, max: maxPanelCenterX),
            y: clamp(desiredPanelCenterY, min: topLimit + panelSize.height / 2, max: maxPanelCenterY)
        )
    }

    var panelFrame: CGRect {
        CGRect(
            x: panelPosition.x - panelSize.width / 2,
            y: panelPosition.y - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    var topLimit: CGFloat {
        max(
            safeAreaInsets.top + AccessDebugOverlayDragBounds.topNavigationControlReserve,
            12
        )
    }

    var bottomLimit: CGFloat {
        containerSize.height
            - max(safeAreaInsets.bottom + AccessDebugOverlayDragBounds.bottomNavigationReserve, 72)
            - AccessDebugOverlayDragBounds.bottomMargin
    }

    private var availableBelow: CGFloat {
        bottomLimit - (capsulePosition.y + capsuleSize.height / 2 + Self.spacing)
    }

    private var availableAbove: CGFloat {
        (capsulePosition.y - capsuleSize.height / 2 - Self.spacing) - topLimit
    }

    private var desiredPanelCenterX: CGFloat {
        switch horizontalAlignment {
        case .leading:
            return capsulePosition.x - capsuleSize.width / 2 + panelSize.width / 2
        case .trailing:
            return capsulePosition.x + capsuleSize.width / 2 - panelSize.width / 2
        }
    }

    private var desiredPanelCenterY: CGFloat {
        switch expansionDirection {
        case .down:
            return capsulePosition.y + capsuleSize.height / 2 + Self.spacing + panelSize.height / 2
        case .up:
            return capsulePosition.y - capsuleSize.height / 2 - Self.spacing - panelSize.height / 2
        }
    }

    private var maxPanelCenterX: CGFloat {
        max(panelSize.width / 2 + AccessDebugOverlayDragBounds.horizontalMargin, containerSize.width - AccessDebugOverlayDragBounds.horizontalMargin - panelSize.width / 2)
    }

    private var maxPanelCenterY: CGFloat {
        max(topLimit + panelSize.height / 2, bottomLimit - panelSize.height / 2)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}

private struct AccessDebugOverlayDragDeformation: ViewModifier {
    let translation: CGSize
    let isDragging: Bool

    func body(content: Content) -> some View {
        let distance = hypot(translation.width, translation.height)
        let hasMotion = isDragging || distance > 0.5
        let cappedDistance = min(distance, 150)
        let stretch = hasMotion ? min(cappedDistance / 460, 0.24) : 0
        let horizontalDominant = abs(translation.width) >= abs(translation.height)
        let compression = stretch * 0.34
        let xScale = 1 + (horizontalDominant ? stretch : -compression)
        let yScale = 1 + (horizontalDominant ? -compression : stretch)
        let rotation = hasMotion ? max(min(translation.width / 16, 9), -9) : 0
        let tail = tailOffset(distance: cappedDistance)

        content
            .background {
                if hasMotion, cappedDistance > 2 {
                    Capsule()
                        .fill(Color.black.opacity(isDragging ? 0.28 : 0.16))
                        .frame(width: max(18, cappedDistance * 0.38), height: 16)
                        .offset(tail)
                        .blur(radius: 0.2)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .scaleEffect(x: xScale, y: yScale, anchor: .center)
            .rotationEffect(.degrees(rotation))
            .shadow(color: Color.black.opacity(isDragging ? 0.28 : 0.16), radius: isDragging ? 14 : 8, x: 0, y: isDragging ? 8 : 4)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.74, blendDuration: 0.04), value: isDragging)
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.72, blendDuration: 0.04), value: translation)
    }

    private func tailOffset(distance: CGFloat) -> CGSize {
        guard distance > 0 else { return .zero }
        let unitX = translation.width / max(distance, 1)
        let unitY = translation.height / max(distance, 1)
        let tailDistance = min(max(distance * 0.12, 4), 14)
        return CGSize(width: -unitX * tailDistance, height: -unitY * tailDistance)
    }
}

private struct AccessDebugOverlayCapsuleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 0, next.height > 0 else { return }
        value = next
    }
}

private struct AccessDebugOverlayPanelSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 0, next.height > 0 else { return }
        value = next
    }
}

private func accessDebugOverlaySizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
}

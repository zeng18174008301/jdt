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

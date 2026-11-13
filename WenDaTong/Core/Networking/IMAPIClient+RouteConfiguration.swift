import Foundation
import CryptoKit
import Dispatch

@MainActor
extension IMAPIClient {
    static func configuredAPIBases(
        platformBase explicitPlatformBase: URL? = nil,
        tenantBase explicitTenantBase: URL? = nil,
        imBase explicitIMBase: URL? = nil,
        defaults: UserDefaults = .standard,
        allowLocalOverride: Bool = allowsRuntimeAPIBaseOverride
    ) -> (platformBase: URL, tenantBase: URL, imBase: URL) {
        (
            configuredAPIBase(
                explicit: explicitPlatformBase,
                defaultsKey: "im2.api.platformBase",
                debugDefault: releasePlaceholderPlatformBase,
                releaseDefault: releasePlaceholderPlatformBase,
                defaults: defaults,
                allowLocalOverride: allowLocalOverride
            ),
            configuredAPIBase(
                explicit: explicitTenantBase,
                defaultsKey: "im2.api.tenantBase",
                debugDefault: releasePlaceholderTenantBase,
                releaseDefault: releasePlaceholderTenantBase,
                defaults: defaults,
                allowLocalOverride: allowLocalOverride
            ),
            configuredAPIBase(
                explicit: explicitIMBase,
                defaultsKey: "im2.api.imBase",
                debugDefault: releasePlaceholderIMBase,
                releaseDefault: releasePlaceholderIMBase,
                defaults: defaults,
                allowLocalOverride: allowLocalOverride
            )
        )
    }

	static func configuredBootstrapHostPlan(
		info: [String: Any] = Bundle.main.infoDictionary ?? [:],
		appID: String = IMAPIContext.canonicalIOSAppID,
		defaults: UserDefaults = .standard,
		allowLocalOverride: Bool = allowsRuntimeAPIBaseOverride
	) -> IMAppBootstrapHostPlan {
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		let packagedPlan = IMAppBootstrapHostConfigurationLoader.load(info: info, appID: appID)
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
        #if DEBUG
        if allowLocalOverride,
		   let rawOverride = defaults.string(forKey: "im2.api.bootstrapBase"),
		   let debugOverride = normalizedHTTPBaseURL(rawOverride, allowLocalOrInsecure: true),
		   // JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		   let configuration = Self.debugBootstrapHostConfiguration(
				override: debugOverride,
				packagedPlan: packagedPlan
		   ) {
		   // JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
			return .configured(configuration)
        }
        #endif
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		return packagedPlan
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
	}

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	static func debugBootstrapHostConfiguration(
		override: URL,
		packagedPlan: IMAppBootstrapHostPlan
	) -> IMAppBootstrapHostConfiguration? {
		let packagedBases: [URL]
		if case .configured(let packagedConfiguration) = packagedPlan {
			packagedBases = packagedConfiguration.orderedBases
		} else {
			packagedBases = []
		}
		let mergedBases = [override] + packagedBases.filter { !Self.sameOrigin($0, override) }
		return IMAppBootstrapHostConfiguration(
			orderedBases: Array(mergedBases.prefix(IMAppBootstrapHostConfiguration.maximumBaseCount)),
			allowLocalOrInsecure: true
		)
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

	static func configuredBootstrapBases(
		defaults: UserDefaults = .standard,
		allowLocalOverride: Bool = allowsRuntimeAPIBaseOverride
	) -> [URL] {
		guard case .configured(let configuration) = configuredBootstrapHostPlan(
			defaults: defaults,
			allowLocalOverride: allowLocalOverride
		) else { return [] }
		return configuration.orderedBases
    }

	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	nonisolated static func configuredAppBootstrapEnvironment(
		info: [String: Any] = Bundle.main.infoDictionary ?? [:]
	) -> String {
		let prelogin = normalizedAppBootstrapEnvironment(info["WXTPreloginBootstrapEnvironment"])
		if !prelogin.isEmpty { return prelogin }
		return normalizedAppBootstrapEnvironment(info["WXTAccessDiscoveryEnvironment"])
	}

	nonisolated static func normalizedAppBootstrapEnvironment(_ raw: Any?) -> String {
		guard let raw = raw as? String else { return "" }
		let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard value == raw.trimmingCharacters(in: .whitespacesAndNewlines),
		      !value.isEmpty,
		      !value.contains("$("),
		      value.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\t")) == nil else {
			return ""
		}
		return value
	}
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

    static func configuredAPIBase(
        explicit: URL?,
        defaultsKey: String,
        debugDefault: URL,
        releaseDefault: URL,
        defaults: UserDefaults,
        allowLocalOverride: Bool
    ) -> URL {
        if let explicit {
            return explicit
        }
        if allowLocalOverride {
            if let localOverride = normalizedHTTPBaseURL(defaults.string(forKey: defaultsKey), allowLocalOrInsecure: true) {
                return localOverride
            }
            return debugDefault
        }
        return releaseDefault
    }

    static func inferredMediaCategory(kind: MessageKind, fileName: String, mimeType: String) -> String {
        let normalizedMime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = (fileName as NSString).pathExtension.lowercased()
        if kind == .voice {
            return "voice"
        }
        if kind == .image || normalizedMime.hasPrefix("image/") || ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"].contains(ext) {
            return "image"
        }
        if kind == .video || normalizedMime.hasPrefix("video/") || ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"].contains(ext) {
            return "video"
        }
        if normalizedMime.contains("pdf") || ext == "pdf" {
            return "pdf"
        }
        if normalizedMime.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext) {
            return "audio"
        }
        return "file"
    }

    static func previewKind(forMediaCategory category: String) -> String {
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "image": return "image"
        case "video": return "video"
        case "pdf": return "pdf"
        case "voice": return "voice"
        case "audio": return "audio"
        default: return "download"
        }
    }

    nonisolated static func normalizedTenantAPIBaseURL(_ rawValue: String?) -> URL? {
        normalizedTenantAPIBaseURL(rawValue, allowLocalOrInsecure: allowsRuntimeAPIBaseOverride)
    }

    nonisolated static func normalizedTenantAPIBaseURL(_ rawValue: String?, allowLocalOrInsecure: Bool) -> URL? {
        normalizedHTTPBaseURL(rawValue, allowLocalOrInsecure: allowLocalOrInsecure)
    }

    nonisolated static func normalizedIMAPIBaseURL(_ rawValue: String?) -> URL? {
        normalizedIMAPIBaseURL(rawValue, allowLocalOrInsecure: allowsRuntimeAPIBaseOverride)
    }

    nonisolated static func normalizedIMAPIBaseURL(_ rawValue: String?, allowLocalOrInsecure: Bool) -> URL? {
        normalizedHTTPBaseURL(rawValue, allowLocalOrInsecure: allowLocalOrInsecure)
    }

    nonisolated static func normalizedHTTPBaseURL(_ rawValue: String?, allowLocalOrInsecure: Bool) -> URL? {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        if !allowLocalOrInsecure {
            guard scheme == "https",
                  !Self.isLocalAPIBaseHost(host) else {
                return nil
            }
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        return components.url
    }

    nonisolated static func isLocalAPIBaseHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1" {
            return true
        }
        if normalized.hasPrefix("127.") || normalized.hasPrefix("0.") {
            return true
        }
        return false
    }

    func tenantBase(for context: IMAPIContext) -> URL {
		if let snapshot = tenantRouteSnapshot,
		   snapshot.appID == context.appID,
		   snapshot.tenantID == context.tenantID,
		   let raw = runtimeRouteSelector.endpoints(snapshot, service: .tenantAPI).first,
		   let routed = Self.normalizedTenantAPIBaseURL(raw) {
			return routed
		}
		return Self.normalizedTenantAPIBaseURL(context.tenantAPIBaseURL) ?? tenantBase
    }

    func preEnterWorkspaceEntryBase(context: IMAPIContext?) async throws -> URL {
        if let context,
           let contextTenantBase = Self.normalizedTenantAPIBaseURL(context.tenantAPIBaseURL),
           !Self.isReleasePlaceholderTenantBase(contextTenantBase) {
            return contextTenantBase
        }
        if !Self.isReleasePlaceholderTenantBase(tenantBase) {
            return tenantBase
        }
        // Before platform enter, the deployment-scoped tenant data-plane URL is
        // not available yet. Never send tenant workspace-entry routes to the
        // platform host; the caller can defer this additive preflight and let
        // the authoritative platform enter response supply tenant_api_base_url.
        throw IMAPIError.missingContext("tenant_api_base_url")
    }

    nonisolated static func isReleasePlaceholderTenantBase(_ url: URL) -> Bool {
        let placeholderScheme = releasePlaceholderTenantBase.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hostlessPlaceholderPath = releasePlaceholderTenantBase.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hostlessPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if url.host == nil,
           releasePlaceholderTenantBase.host == nil,
           scheme == placeholderScheme,
           hostlessPath == hostlessPlaceholderPath {
            return true
        }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let placeholderHost = releasePlaceholderTenantBase.host?.lowercased() else {
            return false
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let placeholderPath = releasePlaceholderTenantBase.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return host == placeholderHost
            && (url.scheme ?? "").lowercased() == (releasePlaceholderTenantBase.scheme ?? "").lowercased()
            && effectiveHTTPSPort(url) == effectiveHTTPSPort(releasePlaceholderTenantBase)
            && path == placeholderPath
    }

    func publicTenantRouteBase(appID: String) async throws -> URL {
        if !Self.isReleasePlaceholderTenantBase(tenantBase) {
            return tenantBase
        }
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        return try await platformAPIBase(
            appID: normalizedAppID.isEmpty ? IMAPIContext.canonicalIOSAppID : normalizedAppID
        )
    }

    func imBase(for context: IMAPIContext) -> URL {
		if let snapshot = tenantRouteSnapshot,
		   snapshot.appID == context.appID,
		   snapshot.tenantID == context.tenantID,
		   let raw = runtimeRouteSelector.endpoints(snapshot, service: .imAPI).first,
		   let routed = Self.normalizedIMAPIBaseURL(raw) {
			return routed
		}
		return Self.normalizedIMAPIBaseURL(context.imAPIBaseURL) ?? imBase
    }

    func webSocketURL(context: IMAPIContext) -> URL? {
        guard !isTenantRuntimeRevoked(appID: context.appID, tenantID: context.tenantID) else { return nil }
        guard let token = context.imToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
		if realtimeRouteFailClosed { return nil }
		if let snapshot = tenantRouteSnapshot,
		   snapshot.appID == context.appID,
		   snapshot.tenantID == context.tenantID,
		   let raw = realtimeEndpoints(snapshot).first,
		   let routed = URL(string: raw) {
			return RealtimeEndpointURLSanitizer.removingCredentials(from: routed)
		}
		if let imRealtimeBase { return RealtimeEndpointURLSanitizer.removingCredentials(from: imRealtimeBase) }
        let base = imBase(for: context)
        #if DEBUG
        if let localProxyURL = Self.localDevelopmentWebSocketProxyURL(base: base) {
            return localProxyURL
        }
        #endif
        guard let endpoint = Self.resolvedURL(base: base, path: Self.imWebSocketRoutePath(for: base)) else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.scheme = (base.scheme == "https") ? "wss" : "ws"
        guard let url = components?.url else { return nil }
        return RealtimeEndpointURLSanitizer.removingCredentials(from: url)
    }

    nonisolated static func imWebSocketRoutePath(for base: URL) -> String {
        let segments = base.path
            .split(separator: "/")
            .map { String($0).lowercased() }
        return segments.last == "im" ? "/ws" : "/im/ws"
    }

    #if DEBUG
    static func localDevelopmentWebSocketProxyURL(base: URL) -> URL? {
        guard let host = base.host,
              isLocalAPIBaseHost(host),
              base.port == 5174 else {
            return nil
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.scheme = (base.scheme == "https") ? "wss" : "ws"
        components?.path = "/im/ws"
        components?.fragment = nil
        guard let url = components?.url else { return nil }
        return RealtimeEndpointURLSanitizer.removingCredentials(from: url)
    }
    #endif

    func baseIMBody(_ context: IMAPIContext) throws -> [String: Any] {
        try requireIM(context)
        return [
            "tenant_id": context.tenantID ?? "",
            "im_uid": context.imUID ?? "",
            "app_id": IMAPIContext.normalizedIOSAppID(context.appID),
            "device_id": context.deviceID
        ]
    }

    func actionBody(_ context: IMAPIContext) throws -> [String: Any] {
        try requireIM(context)
        return [
            "tenant_id": context.tenantID ?? "",
            "app_id": context.appID,
            "device_id": context.deviceID,
            "operator_uid": context.imUID ?? ""
        ]
    }

    func isTenantRuntimeRevoked(appID: String, tenantID: String?) -> Bool {
        guard let tenantID else { return false }
        let watermark = runtimeRouteStore.record(appID: appID, tenantID: tenantID).publicationWatermark
        return ["disabled", "tombstone"].contains(watermark?.status ?? "")
    }

    func requireActiveTenantRoute(_ context: IMAPIContext) throws {
        guard !isTenantRuntimeRevoked(appID: context.appID, tenantID: context.tenantID) else {
            throw IMAPIError.businessForbidden(code: "tenant_service_stopped", message: "企业服务已停用", error: nil)
        }
    }

    func requireIM(_ context: IMAPIContext) throws {
        try requireActiveTenantRoute(context)
        if !context.hasIMSession {
            throw IMAPIError.missingContext("im session")
        }
    }

    static func resolvedURL(
        base: URL,
        path rawPath: String,
        preservePercentEncodedPath: Bool = false
    ) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        if preservePercentEncodedPath {
            return resolvedPercentEncodedURL(base: base, path: path)
        }
        guard var baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return URL(string: path, relativeTo: base)?.absoluteURL
        }
        let requestComponents = URLComponents(string: path)
        let requestPath = requestComponents?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? path
        let basePrefix = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestSuffix = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if requestSuffix.isEmpty {
            baseComponents.path = basePrefix.isEmpty ? "/" : "/\(basePrefix)"
        } else if basePrefix.isEmpty {
            baseComponents.path = "/\(requestSuffix)"
        } else {
            baseComponents.path = "/\(basePrefix)/\(requestSuffix)"
        }
        baseComponents.query = requestComponents?.query
        baseComponents.fragment = requestComponents?.fragment
        return baseComponents.url
    }

    static func resolvedPercentEncodedURL(base: URL, path: String) -> URL? {
        guard var baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return URL(string: path, relativeTo: base)?.absoluteURL
        }
        guard let requestComponents = URLComponents(string: path) else { return nil }
        let requestPath = requestComponents.percentEncodedPath
        let basePrefix = baseComponents.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestSuffix = requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if requestSuffix.isEmpty {
            baseComponents.percentEncodedPath = basePrefix.isEmpty ? "/" : "/\(basePrefix)"
        } else if basePrefix.isEmpty {
            baseComponents.percentEncodedPath = "/\(requestSuffix)"
        } else {
            baseComponents.percentEncodedPath = "/\(basePrefix)/\(requestSuffix)"
        }
        baseComponents.percentEncodedQuery = requestComponents.percentEncodedQuery
        baseComponents.percentEncodedFragment = requestComponents.percentEncodedFragment
        return baseComponents.url
    }

    func channelType(_ kind: ConversationKind) -> String {
        switch kind {
        case .direct: return "direct"
        case .group: return "group"
        case .system: return "system"
        }
    }
}

import Foundation
import CryptoKit
import Dispatch

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

struct MessageSendOutcomeUncertainError: Error {}

enum IMAPIBearerPurpose: Equatable {
    case session
    case messageSend
    case rtc
    // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_NETWORK_PURPOSE - 修改开始：公共媒体 REST 不携带 Bearer，且不触发登录态失效分支
    case publicMedia
    // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_NETWORK_PURPOSE - 修改结束
}

@available(iOS 16.0, *)
private enum IMAppBootstrapModernContinuousClock {
	private static let clock = ContinuousClock()
	private static let origin = clock.now

	static func nowMS() -> UInt64 {
		let components = origin.duration(to: clock.now).components
		guard components.seconds >= 0 else { return 0 }
		let seconds = UInt64(components.seconds)
		let milliseconds = UInt64(max(0, components.attoseconds)) / 1_000_000_000_000_000
		guard seconds <= (UInt64.max - milliseconds) / 1_000 else { return UInt64.max }
		return seconds * 1_000 + milliseconds
	}
}

private enum IMAppBootstrapContinuousClock {
	static func nowMS() -> UInt64 {
		if #available(iOS 16.0, *) {
			return IMAppBootstrapModernContinuousClock.nowMS()
		}
		return DispatchTime.now().uptimeNanoseconds / 1_000_000
	}
}

@MainActor
final class IMAPIClient: IMAPIProtocol {
    struct RTCPolicyObservation {
        let scope: [String]
        let endpoint: URL
        let requiresV1: Bool
        let expiresAt: Date
    }
    var rtcPolicyAdvertisement: RTCPolicyObservation?

    enum RuntimeRouteReplayPolicy: Sendable, Equatable {
        case singleSend
        case readOnly
        case currentEndpointOnly
    }

    struct PreauthDeviceProofPayload: Decodable, Sendable {
        let deviceProof: String
        let expiresAt: String

        private enum CodingKeys: String, CodingKey {
            case deviceProof = "device_proof"
            case expiresAt = "expires_at"
        }
    }

    struct PreauthDeviceProofCacheKey: Hashable, Sendable {
        let tenantBase: String
        let appID: String
        let deviceID: String
    }

    struct PreauthDeviceProofCacheEntry: Sendable {
        let proof: String
        let expiresAt: Date
    }

    struct RawHTTPResult: Sendable {
        let data: Data
        let isHTTPResponse: Bool
        let statusCode: Int?
		let responseURL: URL?
        let requestID: String?
        let retryAfterSeconds: Int?
    }

    struct DecodedAPIResponse<T: Decodable>: @unchecked Sendable {
        let errorEnvelope: APIErrorEnvelope?
        let loginSecurityEnvelope: APILoginSecurityEnvelope?
        let envelope: APIEnvelope<T>?
    }

    let configuredPlatformBase: URL
    let trustedPreloginPlatformBase: URL?
	private(set) var tenantBase: URL
	private(set) var imBase: URL
	var imRealtimeBase: URL?
	let packagedBootstrapHostConfiguration: IMAppBootstrapHostConfiguration?
	var bootstrapHostConfiguration: IMAppBootstrapHostConfiguration?
	let bootstrapConfigurationBlocked: Bool
    let resolvesPlatformBaseViaBootstrap: Bool
    var bootstrapPublicBase: URL?
    var bootstrapPlatformBase: URL?
    var bootstrapMemory: RemoteAppBootstrap?
    var bootstrapMemoryExpiresAt: Date?
	// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	var bootstrapRestoredFromCache = false
	// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
	let runtimeRouteStore: IMRuntimeRouteStore
	lazy var runtimeRouteSelector = IMRuntimeRouteSelector(store: runtimeRouteStore)
	var appRouteSnapshot: IMRuntimeRouteSnapshot?
	var tenantRouteSnapshot: IMRuntimeRouteSnapshot?
    var revokedTenantRuntimeScope: (appID: String, tenantID: String)?
	var accessDiagnosticsRouteHits: [IMRuntimeRouteService: (endpoint: String, tier: IMRuntimeRouteTier)] = [:]
	var realtimeRouteWindow = IMRuntimeRouteRequestWindow()
	var realtimeRouteFailClosed = false
	var realtimePreferredProbeInFlight = false
	var realtimePreferredProbeConnectedAtMS: UInt64?
	var realtimeBackupConnectedAtMS: UInt64?
	var realtimeAttemptStartedMS: UInt64?
	var realtimeAttemptBeganDuringColdLaunch = false
	let runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle
	let runtimeMonotonicNowMS: @MainActor @Sendable () -> UInt64
	let runtimeSleep: @Sendable (UInt64) async throws -> Void
	let bootstrapNetworkReachable: @MainActor @Sendable () -> Bool
    var forcedAuthRequestGate: (@MainActor (IMAPIRequestDescriptor) async throws -> Void)?
    let decoder: JSONDecoder
    let httpTransport: HTTPTransport
    let wireCodec: any WireCodec
    let encoderFormatter = ISO8601DateFormatter()
    let inFlightGETRequests = HTTPInFlightRequestStore<RawHTTPResult>()
    let preauthDeviceProofNow: () -> Date
    var preauthDeviceProofCache: [PreauthDeviceProofCacheKey: PreauthDeviceProofCacheEntry] = [:]
    var preauthDeviceProofFetchTasks: [PreauthDeviceProofCacheKey: Task<PreauthDeviceProofCacheEntry, Error>] = [:]
    var preauthDeviceProofUnavailableUntil: [PreauthDeviceProofCacheKey: Date] = [:]
	var coldLaunchOutcomeRecordedServices = Set<IMRuntimeRouteService>()
	var preferredHTTPProbeInFlightServices = Set<IMRuntimeRouteService>()
	var tenantRouteTransientGeneration: UInt64 = 0
	var bootstrapResolutionCompleted = false

	var configuredAppBootstrapPrimaryBase: URL? { bootstrapHostConfiguration?.primary }
	var configuredAppBootstrapBackupBase: URL? { bootstrapHostConfiguration?.backup }
	var configuredAppBootstrapBases: [URL] { bootstrapHostConfiguration?.orderedBases ?? [] }

	func publishAccessDiagnosticsDomainState() {
		guard AccessDiagnostics.shared.isVisible else { return }
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		let orderedBases = bootstrapHostConfiguration?.orderedBases ?? []
		let firstCandidate = orderedBases.first
		let remainingCandidates = orderedBases.dropFirst()
			.map(\.absoluteString)
			.joined(separator: "、")
		let current = bootstrapPublicBase ?? firstCandidate
		let bootstrapTier: IMRuntimeRouteTier = {
			guard let current, let firstCandidate else { return .preferred }
			return Self.sameOrigin(current, firstCandidate) ? .preferred : .backup
		}()
		let bootstrapSource = bootstrapRestoredFromCache ? "last-good" : "live"
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		AccessDiagnostics.shared.record(
			.bootstrapRoute(
				primaryHost: firstCandidate?.absoluteString ?? "",
				fallbackHost: remainingCandidates.isEmpty ? nil : remainingCandidates,
				currentHost: current?.absoluteString ?? "",
				tier: bootstrapTier,
				source: bootstrapSource
			)
		)
		[appRouteSnapshot, tenantRouteSnapshot].compactMap { $0 }.forEach {
			AccessDiagnostics.shared.record(.runtimeRoutes($0))
		}
		for (service, hit) in accessDiagnosticsRouteHits {
			AccessDiagnostics.shared.record(.routeHit(service: service, endpoint: hit.endpoint, tier: hit.tier))
		}
	}

	func recordAccessDiagnosticsRouteHit(
		service: IMRuntimeRouteService,
		endpoint: URL,
		tier: IMRuntimeRouteTier
	) {
		accessDiagnosticsRouteHits[service] = (endpoint.absoluteString, tier)
		AccessDiagnostics.shared.record(.routeHit(service: service, endpoint: endpoint.absoluteString, tier: tier))
	}

    init(
        platformBase: URL? = nil,
        tenantBase: URL? = nil,
        imBase: URL? = nil,
        bootstrapBases explicitBootstrapBases: [URL]? = nil,
        trustedPreloginPlatformBase: URL? = nil,
        httpTransport: HTTPTransport = URLSessionHTTPTransport(),
        wireCodec: any WireCodec = JSONWireCodec(),
        runtimeRouteStore: IMRuntimeRouteStore = IMRuntimeRouteStore(),
		preauthDeviceProofNow: @escaping () -> Date = { Date() },
		runtimeColdLaunchLifecycle: IMRuntimeColdLaunchLifecycle = .shared,
		runtimeMonotonicNowMS: @escaping @MainActor @Sendable () -> UInt64 = {
			IMAppBootstrapContinuousClock.nowMS()
		},
		runtimeSleep: @escaping @Sendable (UInt64) async throws -> Void = { milliseconds in
			try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
		},
		bootstrapNetworkReachable: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        let defaults = UserDefaults.standard
        let configuredBases = Self.configuredAPIBases(
            platformBase: platformBase,
            tenantBase: tenantBase,
            imBase: imBase,
            defaults: defaults
        )
        self.configuredPlatformBase = configuredBases.platformBase
        self.trustedPreloginPlatformBase = trustedPreloginPlatformBase
        self.tenantBase = configuredBases.tenantBase
        self.imBase = configuredBases.imBase
		let bootstrapPlan: IMAppBootstrapHostPlan
		if let trustedPreloginPlatformBase {
			bootstrapPlan = IMAppBootstrapHostConfiguration(
				primary: trustedPreloginPlatformBase,
				backup: nil,
				allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride
			).map(IMAppBootstrapHostPlan.configured) ?? .blocked
		} else if let explicitBootstrapBases {
			if explicitBootstrapBases.isEmpty {
				bootstrapPlan = .unconfigured
			} else if let configuration = IMAppBootstrapHostConfiguration(
				packagedOrderedBases: explicitBootstrapBases,
				allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride
			) {
				bootstrapPlan = .configured(configuration)
			} else {
				bootstrapPlan = .blocked
			}
		} else {
			bootstrapPlan = Self.configuredBootstrapHostPlan(defaults: defaults)
		}
		switch bootstrapPlan {
		case .configured(let configuration):
			packagedBootstrapHostConfiguration = configuration
			bootstrapHostConfiguration = configuration
			bootstrapConfigurationBlocked = false
		case .unconfigured:
			packagedBootstrapHostConfiguration = nil
			bootstrapHostConfiguration = nil
			bootstrapConfigurationBlocked = false
		case .blocked:
			packagedBootstrapHostConfiguration = nil
			bootstrapHostConfiguration = nil
			bootstrapConfigurationBlocked = true
		}
        self.resolvesPlatformBaseViaBootstrap = configuredBases.platformBase == Self.releasePlaceholderPlatformBase
        self.httpTransport = httpTransport
        self.wireCodec = wireCodec
		self.runtimeRouteStore = runtimeRouteStore
		self.runtimeColdLaunchLifecycle = runtimeColdLaunchLifecycle
		self.runtimeMonotonicNowMS = runtimeMonotonicNowMS
		self.runtimeSleep = runtimeSleep
		self.bootstrapNetworkReachable = bootstrapNetworkReachable ?? {
			!runtimeColdLaunchLifecycle.isTracking || runtimeColdLaunchLifecycle.networkReachable
		}
        self.preauthDeviceProofNow = preauthDeviceProofNow
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        encoderFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if resolvesPlatformBaseViaBootstrap,
		   let restored = runtimeRouteStore.restore(appID: IMAPIContext.canonicalIOSAppID, tenantID: nil) {
			appRouteSnapshot = restored
			restoreRuntimeBases(from: restored)
		}
		let storedContext = IMAPIContext.load()
		let storedAppID = IMAPIContext.normalizedIOSAppID(storedContext.appID)

        if let tenantID = storedContext.tenantID, isTenantRuntimeRevoked(appID: storedAppID, tenantID: tenantID) {
            revokedTenantRuntimeScope = (storedAppID, tenantID)
        }
		if let storedTenantID = storedContext.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !storedAppID.isEmpty, !storedTenantID.isEmpty,
		   let restoredTenant = runtimeRouteStore.restore(appID: storedAppID, tenantID: storedTenantID) {
			tenantRouteSnapshot = restoredTenant
			restoreRuntimeBases(from: restoredTenant)
		}
		if resolvesPlatformBaseViaBootstrap,
		   let packagedBootstrapHostConfiguration {
			let appID = IMAPIContext.canonicalIOSAppID
			let environment = Self.configuredAppBootstrapEnvironment()
			let packagedSnapshots = IMAppBootstrapLastGoodStore.snapshots(
				appID: appID,
				environment: environment,
				servingHosts: packagedBootstrapHostConfiguration.orderedBases.compactMap(\.host)
			)
			let allPackagedSnapshots = IMAppBootstrapLastGoodStore.snapshots(
				appID: appID,
				environment: environment,
				servingHosts: packagedBootstrapHostConfiguration.orderedBases.compactMap(\.host),
				allowExpired: true
			)
			if let cached = Self.highestConsistentCachedBootstrap(
				packagedSnapshots,
				highWaterSnapshots: allPackagedSnapshots,
				appID: appID,
				environment: environment,
				packaged: packagedBootstrapHostConfiguration
			),
			   let platformBases = Self.validatedPlatformBootstrapBases(
				cached.bootstrap,
				packaged: packagedBootstrapHostConfiguration
			   ),
			   let merged = Self.mergedBootstrapHostConfiguration(
				platformBases: platformBases,
				packaged: packagedBootstrapHostConfiguration
			   ) {
				bootstrapHostConfiguration = merged
			}

			if let hosts = bootstrapHostConfiguration {
				let fallbackSnapshots = IMAppBootstrapLastGoodStore.snapshots(
					appID: appID,
					environment: environment,
					servingHosts: hosts.orderedBases.compactMap(\.host)
				)
				let allFallbackSnapshots = IMAppBootstrapLastGoodStore.snapshots(
					appID: appID,
					environment: environment,
					servingHosts: hosts.orderedBases.compactMap(\.host),
					allowExpired: true
				)
				if let cached = Self.highestConsistentCachedBootstrap(
					fallbackSnapshots,
					highWaterSnapshots: allFallbackSnapshots,
					appID: appID,
					environment: environment,
					packaged: packagedBootstrapHostConfiguration
				),
				   let servingBase = hosts.base(matchingBootstrapHost: cached.servingHost),
				   (try? acceptAppBootstrap(
					cached.bootstrap,
					appID: appID,
					selectedBase: servingBase,
					hostConfiguration: hosts,
					restoredFromCache: true,
					persistLastGood: false
				   )) != nil {
					bootstrapMemoryExpiresAt = Date().addingTimeInterval(60)
				}
			}
		}
    }

	func restoreRuntimeBases(from snapshot: IMRuntimeRouteSnapshot) {
		if snapshot.tenantID == nil,
		   let raw = runtimeRouteSelector.endpoints(snapshot, service: .platformAPI).first,
		   let value = Self.normalizedHTTPBaseURL(raw, allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride) {
			bootstrapPlatformBase = value
		}
		if let raw = runtimeRouteSelector.endpoints(snapshot, service: .tenantAPI).first,
		   let value = Self.normalizedHTTPBaseURL(raw, allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride) {
			tenantBase = value
		}
		if let raw = runtimeRouteSelector.endpoints(snapshot, service: .imAPI).first,
		   let value = Self.normalizedHTTPBaseURL(raw, allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride) {
			imBase = value
		}
		if let raw = runtimeRouteSelector.endpoints(snapshot, service: .imRealtime).first {
			imRealtimeBase = URL(string: raw)
		}
		publishAccessDiagnosticsDomainState()
	}

	func runtimeColdLaunchSceneDidBecomeAvailable(isActive: Bool) {
		if isActive { runtimeColdLaunchLifecycle.sceneDidBecomeActive() }
		else { runtimeColdLaunchLifecycle.sceneDidBecomeInactive() }
	}

	func runtimeColdLaunchSceneDidBecomeInactive() {
		runtimeColdLaunchLifecycle.sceneDidBecomeInactive()
	}

	func runtimeColdLaunchSceneDidEnterBackground() {
		runtimeColdLaunchLifecycle.sceneDidEnterBackground()
	}

	func finishRuntimeColdLaunch() {
		runtimeColdLaunchLifecycle.finish()
	}

    var platformBase: URL {
        bootstrapPlatformBase ?? configuredPlatformBase
    }

    nonisolated static var allowsRuntimeAPIBaseOverride: Bool {
        #if DEBUG
        IMRuntimeBuildPolicy.allowsRuntimeAPIBaseOverride(debugBuild: true)
        #else
        false
        #endif
    }

	nonisolated static let releasePlaceholderPlatformBase = URL(string: "about:blank")!
	nonisolated static let releasePlaceholderTenantBase = URL(string: "about:blank")!
	nonisolated static let releasePlaceholderIMBase = URL(string: "about:blank")!

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

	func realtimeEndpoints(_ snapshot: IMRuntimeRouteSnapshot) -> [String] {
		if realtimePreferredProbeInFlight,
		   let route = snapshot.services[IMRuntimeRouteService.imRealtime.rawValue] {
			return route.preferred + route.backups
		}
		let tiers = runtimeRouteSelector.endpointTiers(snapshot, service: .imRealtime)
		let persistentRecovery = runtimeRouteSelector.recovery(snapshot, service: .imRealtime).recovery
		if !persistentRecovery, realtimeRouteWindow.tier == .backup, !tiers.backups.isEmpty {
			return tiers.backups + tiers.preferred
		}
		return tiers.preferred + tiers.backups
	}

	func runtimeRealtimeConnectionRequest(context: IMAPIContext) -> RealtimeConnectionRequest? {
		guard tenantRouteSnapshot != nil,
		      let token = context.imToken,
		      let url = webSocketURL(context: context) else { return nil }
		if realtimeAttemptStartedMS == nil {
			realtimeAttemptStartedMS = runtimeMonotonicNowMS()
			realtimeAttemptBeganDuringColdLaunch = runtimeColdLaunchLifecycle.isTracking
		}
		return RealtimeConnectionRequest(url: url, token: token)
	}

	func recordRuntimeRealtimeFailure(_ error: Error, context: IMAPIContext) {
		guard let snapshot = tenantRouteSnapshot,
		      snapshot.appID == context.appID,
		      snapshot.tenantID == context.tenantID else { return }
		let failure = Self.runtimeRouteFailure(for: error)
		realtimePreferredProbeInFlight = false
		realtimePreferredProbeConnectedAtMS = nil
		realtimeBackupConnectedAtMS = nil
		let nowMS = runtimeMonotonicNowMS()
		realtimeRouteWindow = realtimeRouteWindow.recording(failure, nowMS: nowMS)
		if failure.decision == .failClosed {
			realtimeRouteFailClosed = true
			recordRuntimeRealtimeColdLaunchUnqualifiedIfNeeded(snapshot: snapshot, cancelled: false)
			return
		}
		guard failure.decision == .qualifiedNetwork else {
			recordRuntimeRealtimeColdLaunchUnqualifiedIfNeeded(snapshot: snapshot, cancelled: failure == .cancelled)
			realtimeAttemptStartedMS = nil
			realtimeAttemptBeganDuringColdLaunch = false
			return
		}
		let startedMS = realtimeAttemptStartedMS ?? nowMS
		let elapsedMS = nowMS >= startedMS ? nowMS - startedMS : 0
		if elapsedMS >= snapshot.policy.preferredFailureBudgetMS {
			realtimeRouteWindow = .init(firstQualifiedFailureAtMS: startedMS, tier: .backup)
			recordRuntimeRealtimeColdLaunchFailureIfNeeded(snapshot: snapshot, durationMS: elapsedMS)
		}
	}

	func installValidatedTenantRouteSnapshot(_ snapshot: IMRuntimeRouteSnapshot) {
        revokedTenantRuntimeScope = nil
		let authorityChanged = tenantRouteSnapshot?.appID != snapshot.appID
			|| tenantRouteSnapshot?.tenantID != snapshot.tenantID
			|| tenantRouteSnapshot?.revision != snapshot.revision
			|| tenantRouteSnapshot?.configHash != snapshot.configHash
		if authorityChanged {
			resetRuntimeRouteTransientStateForTenantScope()
		}
		tenantRouteSnapshot = snapshot
		restoreRuntimeBases(from: snapshot)
	}

	func resetRuntimeRouteTransientStateForTenantScope() {
		tenantRouteTransientGeneration &+= 1
		realtimeRouteWindow = .init()
		realtimeRouteFailClosed = false
		realtimePreferredProbeInFlight = false
		realtimePreferredProbeConnectedAtMS = nil
		realtimeBackupConnectedAtMS = nil
		realtimeAttemptStartedMS = nil
		realtimeAttemptBeganDuringColdLaunch = false
		preferredHTTPProbeInFlightServices.subtract([.tenantAPI, .imAPI, .imRealtime])
	}

	func runtimeProbeAuthorityIsCurrent(
		_ snapshot: IMRuntimeRouteSnapshot,
		tenantGeneration: UInt64?
	) -> Bool {
		let current = snapshot.tenantID == nil ? appRouteSnapshot : tenantRouteSnapshot
		guard current?.appID == snapshot.appID,
		      current?.tenantID == snapshot.tenantID,
		      current?.revision == snapshot.revision,
		      current?.configHash == snapshot.configHash else { return false }
		return tenantGeneration == nil || tenantGeneration == tenantRouteTransientGeneration
	}

	func prepareRuntimeRealtimePreferredProbe(context: IMAPIContext) -> Bool {
		guard let snapshot = tenantRouteSnapshot,
		      snapshot.appID == context.appID,
		      snapshot.tenantID == context.tenantID,
		      !realtimePreferredProbeInFlight,
		      runtimeRouteSelector.recovery(snapshot, service: .imRealtime).recovery,
		      snapshot.services[IMRuntimeRouteService.imRealtime.rawValue]?.preferred.isEmpty == false,
		      let backupConnectedAtMS = realtimeBackupConnectedAtMS else { return false }
		let nowMS = runtimeMonotonicNowMS()
		guard nowMS >= backupConnectedAtMS,
		      nowMS - backupConnectedAtMS >= snapshot.policy.preferredProbeStableMS else { return false }
		realtimePreferredProbeInFlight = true
		realtimePreferredProbeConnectedAtMS = nil
		realtimeBackupConnectedAtMS = nil
		realtimeAttemptStartedMS = nil
		return true
	}

	func recordRuntimeRealtimeConnected(context: IMAPIContext) {
		guard let snapshot = tenantRouteSnapshot,
		      snapshot.appID == context.appID,
		      snapshot.tenantID == context.tenantID else { return }
		if realtimePreferredProbeInFlight {
			realtimePreferredProbeConnectedAtMS = runtimeMonotonicNowMS()
			realtimeAttemptStartedMS = nil
			return
		}
		let connectedToBackup = runtimeRouteSelector.recovery(snapshot, service: .imRealtime).recovery
			|| realtimeRouteWindow.tier == .backup
		if connectedToBackup {
			if realtimeBackupConnectedAtMS == nil { realtimeBackupConnectedAtMS = runtimeMonotonicNowMS() }
		} else {
			realtimeBackupConnectedAtMS = nil
		}
		if !connectedToBackup,
		   realtimeAttemptBeganDuringColdLaunch,
		   coldLaunchOutcomeRecordedServices.insert(.imRealtime).inserted {
			runtimeRouteSelector.recordColdLaunchSuccess(snapshot: snapshot, service: .imRealtime)
		}
		realtimeAttemptStartedMS = nil
		realtimeAttemptBeganDuringColdLaunch = false
		if !connectedToBackup { realtimeRouteWindow = .init() }
	}

	func completeRuntimeRealtimePreferredProbe(context: IMAPIContext) -> Bool {
		guard realtimePreferredProbeInFlight,
		      let connectedAtMS = realtimePreferredProbeConnectedAtMS,
		      let snapshot = tenantRouteSnapshot,
		      snapshot.appID == context.appID,
		      snapshot.tenantID == context.tenantID else { return false }
		let nowMS = runtimeMonotonicNowMS()
		let stableMS = nowMS >= connectedAtMS ? nowMS - connectedAtMS : 0
		guard stableMS >= snapshot.policy.preferredProbeStableMS else { return false }
		runtimeRouteSelector.recordPreferredProbe(
			snapshot: snapshot,
			service: .imRealtime,
			kind: .realtime,
			succeeded: true,
			stableMS: stableMS,
			nowMS: nowMS,
			connectAcknowledged: true
		)
		realtimePreferredProbeInFlight = false
		realtimePreferredProbeConnectedAtMS = nil
		realtimeBackupConnectedAtMS = nil
		realtimeRouteWindow = .init()
		return !runtimeRouteSelector.recovery(snapshot, service: .imRealtime).recovery
	}

	func recordRuntimeRealtimeColdLaunchFailureIfNeeded(snapshot: IMRuntimeRouteSnapshot, durationMS: UInt64) {
		guard realtimeAttemptBeganDuringColdLaunch,
		      !runtimeRouteSelector.recovery(snapshot, service: .imRealtime).recovery,
		      coldLaunchOutcomeRecordedServices.insert(.imRealtime).inserted else { return }
		let attempt = runtimeColdLaunchLifecycle.attempt(qualifiedFailureDurationMS: durationMS)
		runtimeRouteSelector.recordColdLaunch(attempt, snapshot: snapshot, service: .imRealtime)
	}

	func recordRuntimeRealtimeColdLaunchUnqualifiedIfNeeded(snapshot: IMRuntimeRouteSnapshot, cancelled: Bool) {
		guard realtimeAttemptBeganDuringColdLaunch,
		      !runtimeRouteSelector.recovery(snapshot, service: .imRealtime).recovery,
		      coldLaunchOutcomeRecordedServices.insert(.imRealtime).inserted else { return }
		let attempt = runtimeColdLaunchLifecycle.attempt(qualifiedFailureDurationMS: 0, cancelled: cancelled)
		runtimeRouteSelector.recordColdLaunch(attempt, snapshot: snapshot, service: .imRealtime)
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

    static func friendProfilePath(canonicalFriendUID: String) throws -> String {
        let normalizedUID = canonicalFriendUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty else {
            throw IMAPIError.missingContext("friend_uid")
        }
        return "/api/tenant/friends/\(try normalizedUID.urlPathSegmentEncoded())"
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

    func request<T: Decodable>(
        base: URL,
        path: String,
        method: String = "GET",
        bearer: String? = nil,
        body: [String: Any]? = nil,
        additionalHeaders: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        preserveHTTPStatusErrors: Bool = false,
		requiredHTTPStatus: Int? = nil,
        preserveRTCSignalErrorDetails: Bool = false,
        timeoutInterval: TimeInterval? = nil,
        bearerPurpose: IMAPIBearerPurpose = .session,
		classifyUncertainMessageSendOutcome: Bool = false,
		classifyUncertainRegistrationOutcome: Bool = false,
		propagateTaskCancellation: Bool = false,
		runtimeRouteReplayPolicy: RuntimeRouteReplayPolicy = .singleSend,
		expectedResponseOrigin: URL? = nil,
        preservePercentEncodedPath: Bool = false,
        requiredRTCEndpoint: URL? = nil,
        validateRTCRequest: (@MainActor () throws -> Void)? = nil
    ) async throws -> T {
        if let diagnostic = SyncFailureDiagnostic.friendAcceptance, diagnostic.matches(method: method, path: path) {
            diagnostic.record(.routing)
        }
        if path.hasPrefix("/api/tenant/") || path.hasPrefix("/api/im/") {
            let scope = revokedTenantRuntimeScope ?? tenantRouteSnapshot.flatMap { snapshot in
                snapshot.tenantID.map { (appID: snapshot.appID, tenantID: $0) }
            }
            if let scope, isTenantRuntimeRevoked(appID: scope.appID, tenantID: scope.tenantID) {
                throw IMAPIError.businessForbidden(code: "tenant_service_stopped", message: "企业服务已停用", error: nil)
            }
        }
        if let requiredRTCEndpoint {
            try Task.checkCancellation()
            let route = runtimeRoutePlan(base: base, path: path)
            let actual = route?.primary.compactMap { URL(string: $0) }.first ?? (route == nil ? base : nil)
            guard path.hasPrefix("/api/rtc/"), actual == requiredRTCEndpoint,
                  runtimeRouteReplayPolicy == .currentEndpointOnly else { throw CancellationError() }
        }
		guard let plan = runtimeRoutePlan(base: base, path: path) else {
			return try await requestOnce(
				base: base, path: path, method: method, bearer: bearer, body: body,
				additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
				preserveHTTPStatusErrors: preserveHTTPStatusErrors,
				requiredHTTPStatus: requiredHTTPStatus,
				preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
				timeoutInterval: timeoutInterval, bearerPurpose: bearerPurpose,
				classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome,
				classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
				propagateTaskCancellation: propagateTaskCancellation,
				expectedResponseOrigin: expectedResponseOrigin,
                preservePercentEncodedPath: preservePercentEncodedPath,
                validateRTCRequest: validateRTCRequest
			)
		}
		let preferredBudgetMS = plan.snapshot.policy.preferredFailureBudgetMS
		let configuredTimeout = timeoutInterval ?? Self.timeoutInterval(for: path, method: method)
		let primaryAttemptStartedMS = runtimeMonotonicNowMS()
		let primaryDeadlineMS = primaryAttemptStartedMS > UInt64.max - preferredBudgetMS
			? UInt64.max
			: primaryAttemptStartedMS + preferredBudgetMS
		let beganDuringColdLaunch = runtimeColdLaunchLifecycle.isTracking
		let canReplayAcrossEndpoints = Self.canReplayAcrossRuntimeRouteEndpoints(
			method: method,
			policy: runtimeRouteReplayPolicy
		)
		var lastQualifiedError: Error?
		var attemptedEndpoint = false
		for endpoint in plan.primary {
			guard let candidate = URL(string: endpoint) else { continue }
			if attemptedEndpoint, !canReplayAcrossEndpoints { break }
			let nowMS = runtimeMonotonicNowMS()
			guard nowMS < primaryDeadlineMS else { break }
			let remainingSeconds = TimeInterval(primaryDeadlineMS - nowMS) / 1_000
			// A registration POST cannot be replayed on a backup. Preserve its
			// existing request timeout instead of shortening it to a route probe budget.
			let isRegistrationPost = classifyUncertainRegistrationOutcome && method.uppercased() == "POST"
			let attemptTimeout = isRegistrationPost ? configuredTimeout : min(configuredTimeout, remainingSeconds)
			guard attemptTimeout > 0 else { break }
			attemptedEndpoint = true
			do {
                    if let requiredRTCEndpoint, candidate != requiredRTCEndpoint {
                        throw CancellationError()
                    }
				let value: T = try await requestOnce(
					base: candidate, path: path, method: method, bearer: bearer, body: body,
					additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
					preserveHTTPStatusErrors: preserveHTTPStatusErrors,
					requiredHTTPStatus: requiredHTTPStatus,
					preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
					timeoutInterval: attemptTimeout, bearerPurpose: bearerPurpose,
					classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome,
					classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
					propagateTaskCancellation: propagateTaskCancellation,
                    expectedResponseOrigin: requiredRTCEndpoint ?? expectedResponseOrigin,
                    preservePercentEncodedPath: preservePercentEncodedPath,
                    validateRTCRequest: validateRTCRequest
				)
				recordRuntimeColdLaunchSuccessIfNeeded(
					beganDuringColdLaunch: beganDuringColdLaunch,
					plan: plan
				)
				if requiredRTCEndpoint == nil, plan.recovery, method.uppercased() == "GET", body == nil,
				   let preferredEndpoint = plan.backups.first, let preferredBase = URL(string: preferredEndpoint) {
					schedulePreferredHTTPProbe(
						T.self,
						base: preferredBase,
						path: path,
						bearer: bearer,
						additionalHeaders: additionalHeaders,
						preserveHTTPStatusErrors: preserveHTTPStatusErrors,
						preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
						timeoutInterval: attemptTimeout,
						bearerPurpose: bearerPurpose,
						plan: plan,
                        preservePercentEncodedPath: preservePercentEncodedPath
					)
				}
				recordAccessDiagnosticsRouteHit(
					service: plan.service,
					endpoint: candidate,
					tier: plan.recovery ? .backup : .preferred
				)
				return value
			} catch {
				let failure = Self.runtimeRouteFailure(for: error)
				guard failure.decision == .qualifiedNetwork else {
					recordRuntimeColdLaunchUnqualifiedIfNeeded(
						beganDuringColdLaunch: beganDuringColdLaunch,
						plan: plan,
						cancelled: failure == .cancelled
					)
					throw error
				}
				lastQualifiedError = error
			}
		}
		if lastQualifiedError != nil, canReplayAcrossEndpoints {
			let nowMS = runtimeMonotonicNowMS()
			let remainingMS = nowMS < primaryDeadlineMS ? primaryDeadlineMS - nowMS : 0
			if remainingMS > 0 {
				do {
					try await runtimeSleep(remainingMS)
				} catch {
					recordRuntimeColdLaunchUnqualifiedIfNeeded(
						beganDuringColdLaunch: beganDuringColdLaunch,
						plan: plan,
						cancelled: true
					)
					throw error
				}
			}
		}
		if lastQualifiedError != nil {
			let completedMS = runtimeMonotonicNowMS()
			let elapsedMS = completedMS >= primaryAttemptStartedMS ? completedMS - primaryAttemptStartedMS : 0
			recordRuntimeColdLaunchFailureIfNeeded(
				beganDuringColdLaunch: beganDuringColdLaunch,
				plan: plan,
				qualifiedFailureDurationMS: elapsedMS
			)
		}
		if attemptedEndpoint, !canReplayAcrossEndpoints, let lastQualifiedError {
			throw lastQualifiedError
		}
		for endpoint in plan.backups {
			guard let candidate = URL(string: endpoint) else { continue }
			if attemptedEndpoint, !canReplayAcrossEndpoints { break }
			attemptedEndpoint = true
			do {
                    if let requiredRTCEndpoint, candidate != requiredRTCEndpoint {
                        throw CancellationError()
                    }
				let value: T = try await requestOnce(
					base: candidate, path: path, method: method, bearer: bearer, body: body,
					additionalHeaders: additionalHeaders, cachePolicy: cachePolicy,
					preserveHTTPStatusErrors: preserveHTTPStatusErrors,
					requiredHTTPStatus: requiredHTTPStatus,
					preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
					timeoutInterval: timeoutInterval, bearerPurpose: bearerPurpose,
					classifyUncertainMessageSendOutcome: classifyUncertainMessageSendOutcome,
					classifyUncertainRegistrationOutcome: classifyUncertainRegistrationOutcome,
					propagateTaskCancellation: propagateTaskCancellation,
					expectedResponseOrigin: expectedResponseOrigin,
                    preservePercentEncodedPath: preservePercentEncodedPath,
                    validateRTCRequest: validateRTCRequest
				)
				recordAccessDiagnosticsRouteHit(
					service: plan.service,
					endpoint: candidate,
					tier: plan.recovery ? .preferred : .backup
				)
				return value
			} catch {
				let failure = Self.runtimeRouteFailure(for: error)
				guard failure.decision == .qualifiedNetwork else { throw error }
				lastQualifiedError = error
			}
		}
		throw lastQualifiedError ?? IMAPIError.server("服务路由暂不可用")
	}

	static func canReplayAcrossRuntimeRouteEndpoints(
		method: String,
		policy: RuntimeRouteReplayPolicy
	) -> Bool {
		if policy == .currentEndpointOnly {
			return false
		}
		if ["GET", "HEAD", "OPTIONS"].contains(method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) {
			return true
		}
		return policy == .readOnly
	}

	func recordRuntimeColdLaunchSuccessIfNeeded(
		beganDuringColdLaunch: Bool,
		plan: (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool)
	) {
		guard beganDuringColdLaunch, !plan.recovery,
		      coldLaunchOutcomeRecordedServices.insert(plan.service).inserted else { return }
		runtimeRouteSelector.recordColdLaunchSuccess(snapshot: plan.snapshot, service: plan.service)
	}

	func recordRuntimeColdLaunchUnqualifiedIfNeeded(
		beganDuringColdLaunch: Bool,
		plan: (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool),
		cancelled: Bool
	) {
		guard beganDuringColdLaunch, !plan.recovery,
		      coldLaunchOutcomeRecordedServices.insert(plan.service).inserted else { return }
		let attempt = runtimeColdLaunchLifecycle.attempt(qualifiedFailureDurationMS: 0, cancelled: cancelled)
		runtimeRouteSelector.recordColdLaunch(attempt, snapshot: plan.snapshot, service: plan.service)
	}

	func recordRuntimeColdLaunchFailureIfNeeded(
		beganDuringColdLaunch: Bool,
		plan: (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool),
		qualifiedFailureDurationMS: UInt64
	) {
		guard beganDuringColdLaunch, !plan.recovery,
		      coldLaunchOutcomeRecordedServices.insert(plan.service).inserted else { return }
		let attempt = runtimeColdLaunchLifecycle.attempt(qualifiedFailureDurationMS: qualifiedFailureDurationMS)
		runtimeRouteSelector.recordColdLaunch(attempt, snapshot: plan.snapshot, service: plan.service)
	}

	func runtimeRoutePlan(
		base: URL,
		path: String
	) -> (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool)? {
		let normalizedPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
		guard normalizedPath != "/.well-known/wenxintong-app.json",
		      normalizedPath != "/api/app/bootstrap" else { return nil }
		let service: IMRuntimeRouteService
			if normalizedPath.hasPrefix("/api/platform/")
				// JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：平台 legal-docs 走 PlatformAPI 运行时路由
				|| normalizedPath == "/api/app/legal-docs"
				// JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束
			{
				service = .platformAPI
		} else if normalizedPath.hasPrefix("/api/im/") {
			service = .imAPI
		} else if normalizedPath.hasPrefix("/api/tenant/") || normalizedPath.hasPrefix("/api/rtc/") {
			service = .tenantAPI
		} else if let snapshot = tenantRouteSnapshot,
		          snapshot.services[IMRuntimeRouteService.tenantAPI.rawValue]?.preferred.contains(where: { URL(string: $0)?.host == base.host }) == true {
			service = .tenantAPI
		} else {
			return nil
		}
		let snapshot = service == .platformAPI ? appRouteSnapshot : tenantRouteSnapshot
		guard let snapshot else { return nil }
		let recovery = runtimeRouteSelector.recovery(snapshot, service: service).recovery
		let tiers = runtimeRouteSelector.endpointTiers(snapshot, service: service)
		guard !tiers.preferred.isEmpty || !tiers.backups.isEmpty else { return nil }
		return (snapshot, service, tiers.preferred, tiers.backups, recovery)
	}

	func schedulePreferredHTTPProbe<T: Decodable>(
		_ responseType: T.Type,
		base: URL,
		path: String,
		bearer: String?,
		additionalHeaders: [String: String],
		preserveHTTPStatusErrors: Bool,
		preserveRTCSignalErrorDetails: Bool,
		timeoutInterval: TimeInterval,
		bearerPurpose: IMAPIBearerPurpose,
		plan: (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool),
        preservePercentEncodedPath: Bool
	) {
		let stableMS = plan.snapshot.policy.preferredProbeStableMS
		guard preferredHTTPProbeInFlightServices.insert(plan.service).inserted else { return }
		let tenantGeneration: UInt64? = plan.snapshot.tenantID == nil ? nil : tenantRouteTransientGeneration
		Task { @MainActor [weak self] in
			guard let self else { return }
			defer {
				if self.runtimeProbeAuthorityIsCurrent(plan.snapshot, tenantGeneration: tenantGeneration) {
					self.preferredHTTPProbeInFlightServices.remove(plan.service)
				}
			}
			do {
				try await self.runtimeSleep(stableMS)
				for ordinal in 0..<plan.snapshot.policy.preferredProbeSuccesses {
					if ordinal > 0 { try await self.runtimeSleep(plan.snapshot.policy.preferredProbeIntervalMS) }
					guard self.runtimeProbeAuthorityIsCurrent(
						plan.snapshot, tenantGeneration: tenantGeneration
					) else { return }
					let _: T = try await self.requestOnce(
						base: base, path: path, method: "GET", bearer: bearer, body: nil,
						additionalHeaders: additionalHeaders, cachePolicy: .reloadIgnoringLocalCacheData,
						preserveHTTPStatusErrors: preserveHTTPStatusErrors,
						preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
						timeoutInterval: TimeInterval(plan.snapshot.policy.preferredFailureBudgetMS) / 1_000,
						bearerPurpose: bearerPurpose,
						propagateTaskCancellation: true,
                        preservePercentEncodedPath: preservePercentEncodedPath
					)
					self.runtimeRouteSelector.recordPreferredProbe(
						snapshot: plan.snapshot, service: plan.service, kind: .http,
						succeeded: true, stableMS: stableMS,
						nowMS: self.runtimeMonotonicNowMS()
					)
					guard self.runtimeRouteSelector.recovery(plan.snapshot, service: plan.service).recovery else { return }
				}
			} catch {
				guard self.runtimeProbeAuthorityIsCurrent(
					plan.snapshot, tenantGeneration: tenantGeneration
				) else { return }
				self.runtimeRouteSelector.recordPreferredProbe(
					snapshot: plan.snapshot, service: plan.service, kind: .http,
					succeeded: false, stableMS: 0,
					nowMS: self.runtimeMonotonicNowMS()
				)
			}
		}
		_ = responseType
	}

    func requestOnce<T: Decodable>(
        base: URL,
        path: String,
        method: String = "GET",
        bearer: String? = nil,
        body: [String: Any]? = nil,
        additionalHeaders: [String: String] = [:],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        preserveHTTPStatusErrors: Bool = false,
		requiredHTTPStatus: Int? = nil,
        preserveRTCSignalErrorDetails: Bool = false,
        timeoutInterval: TimeInterval? = nil,
        bearerPurpose: IMAPIBearerPurpose = .session,
		classifyUncertainMessageSendOutcome: Bool = false,
		classifyUncertainRegistrationOutcome: Bool = false,
		propagateTaskCancellation: Bool = false,
		expectedResponseOrigin: URL? = nil,
        preservePercentEncodedPath: Bool = false,
        validateRTCRequest: (@MainActor () throws -> Void)? = nil
    ) async throws -> T {
        SyncFailureDiagnostic.httpObservation?.beginUploadStep()
        let acceptanceDiagnostic = SyncFailureDiagnostic.friendAcceptance.flatMap {
            $0.matches(method: method, path: path) ? $0 : nil
        }
        acceptanceDiagnostic?.record(.preparing, endpoint: base)
        guard let url = Self.resolvedURL(
            base: base,
            path: path,
            preservePercentEncodedPath: preservePercentEncodedPath
        ) else {
            throw IMAPIError.badURL(path)
        }
        if let forcedAuthRequestGate {
            try await forcedAuthRequestGate(
                IMAPIRequestDescriptor(
                    base: base,
                    path: path,
                    method: method,
                    hasBearerToken: bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                )
            )
        }
        try validateRTCRequest?()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = cachePolicy
        request.timeoutInterval = timeoutInterval ?? Self.timeoutInterval(for: path, method: method)
        request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (field, rawValue) in additionalHeaders
            where field.caseInsensitiveCompare("Idempotency-Key") == .orderedSame {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                request.setValue(value, forHTTPHeaderField: "Idempotency-Key")
            }
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try wireCodec.encodeJSONObject(body)
            } catch {
                SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(code: .requestEncoding))
                throw error
            }
        }
        let rawResult: RawHTTPResult
        let dedupeKey = Self.idempotentGETRequestKey(base: base, path: path, method: method, bearer: bearer, body: body)
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
#if DEBUG
        // Only the existing registration submission and typed confirmation
        // entrypoints opt in. Observe before uncertain-outcome conversion loses
        // the HTTP distinction; do not open the suppressed generic HTTP logs.
        let observesRegistration = classifyUncertainRegistrationOutcome || T.self == RemoteRegistrationConfirmation.self
        var registrationDiagnostic: RegistrationDiagnosticState? = observesRegistration
            ? (classifyUncertainRegistrationOutcome ? .submitContractFailed : .statusContractFailed)
            : nil
        defer {
            if let registrationDiagnostic {
                recordRegistrationDiagnostic(
                    registrationDiagnostic,
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - requestStartedAt
                )
            }
        }
#endif
        logHTTPRequestStart(method: method, url: url, bodyData: request.httpBody, dedupeKey: dedupeKey)
        acceptanceDiagnostic?.record(.transportStarted, endpoint: base)
        do {
            rawResult = try await rawHTTPResult(
                for: request,
                dedupeKey: dedupeKey,
				propagateTaskCancellation: propagateTaskCancellation,
				expectedResponseOrigin: expectedResponseOrigin
            )
        } catch {
#if DEBUG
            if observesRegistration {
                registrationDiagnostic = .transportFailure(isSubmission: classifyUncertainRegistrationOutcome, error: error)
            }
#endif
            logRequestFailure(method: method, url: url, statusCode: nil, errorCode: "transport", requestID: nil, error: error)
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(error: error))
            if classifyUncertainMessageSendOutcome {
                throw MessageSendOutcomeUncertainError()
            }
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw error
        }
        try validateRTCRequest?()
        let elapsedMS = Int((CFAbsoluteTimeGetCurrent() - requestStartedAt) * 1000)
        guard rawResult.isHTTPResponse, let statusCode = rawResult.statusCode else {
            logRequestFailure(method: method, url: url, statusCode: nil, errorCode: "invalid_response", requestID: nil, error: nil)
            if classifyUncertainMessageSendOutcome {
                throw MessageSendOutcomeUncertainError()
            }
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw IMAPIError.emptyResponse
        }
        SyncFailureDiagnostic.httpObservation?.recordPrimaryResponse(
            path: path, status: statusCode,
            fingerprint: rawResult.requestID.map {
                "hash:" + SHA256.hash(data: Data($0.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
            },
            resolvedPath: url.path
        )
#if DEBUG
        if observesRegistration {
            registrationDiagnostic = .httpResponse(isSubmission: classifyUncertainRegistrationOutcome, statusCode: statusCode)
        }
#endif
		if let expectedResponseOrigin {
			guard let responseURL = rawResult.responseURL,
			      Self.sameOrigin(responseURL, expectedResponseOrigin) else {
				throw IMAPIError.businessForbidden(
					code: "bootstrap_host_mismatch",
					message: "应用启动响应来源不匹配",
					error: nil
				)
			}
		}
        let data = rawResult.data
        // Capture the actual envelope code and trace before the existing error
        // branches normalize them to .server(String) and a generic UI toast.
        acceptanceDiagnostic?.record(.response, endpoint: base, status: statusCode,
                                     responseData: data, requestID: rawResult.requestID)
        logHTTPResponse(method: method, url: url, statusCode: statusCode, requestID: rawResult.requestID, data: data, elapsedMS: elapsedMS)
		if let requiredHTTPStatus, statusCode != requiredHTTPStatus {
			logRequestFailure(
				method: method,
				url: url,
				statusCode: statusCode,
				errorCode: "http_\(statusCode)",
				requestID: rawResult.requestID,
				error: nil
			)
			throw IMAPIError.httpStatus(
				statusCode,
				message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
			)
		}
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let decoded: DecodedAPIResponse<T> = decodeAPIResponse(from: data)
        let decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
        if decodeMs > 80, SyncFailureDiagnostic.friendAcceptance == nil {
            print("[JHT Perf] api_decode_ms=\(decodeMs) method=\(method) path=\(Self.redactedPathForLog(path)) bytes=\(data.count)")
        }
        let errorEnvelope = decoded.errorEnvelope
        let loginSecurityEnvelope = decoded.loginSecurityEnvelope
        let envelope = decoded.envelope
        let errorBody = errorEnvelope?.resolvedError ?? envelope?.error ?? loginSecurityEnvelope?.resolvedError
        let requestID = rawResult.requestID
        let errorCode = Self.effectiveErrorCode(for: errorBody) ?? ""
        // JHT_MOD_BEGIN REGISTRATION_ERROR_CODE_COPY_20260913 - 修改开始：注册 503 中明确的回执/状态错误保留 code，交给 AppState 继续原确认流程并展示文案
        if classifyUncertainRegistrationOutcome,
           statusCode == 503,
           ["registration_request_already_submitted", "registration_status_unavailable"]
            .contains(errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: Self.userMessage(for: errorBody, fallback: "正在确认注册结果，请勿重复提交。"),
                error: errorBody
            )
        }
        // JHT_MOD_END REGISTRATION_ERROR_CODE_COPY_20260913 - 修改结束
        if classifyUncertainRegistrationOutcome, (500..<600).contains(statusCode) {
            throw RegistrationOutcomeUncertainError()
        }
        if !preserveHTTPStatusErrors,
           [502, 503, 504].contains(statusCode),
           errorCode.isEmpty {
            SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(code: .http, httpStatus: statusCode))
            throw IMAPIError.httpStatus(
                statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
        }
        if statusCode == 422 && errorCode == "captcha_device_proof_required" {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: Self.userMessage(for: errorBody, fallback: "设备验证已失效，请重试"),
                error: errorBody
            )
        }
        if errorCode == "security_blocked" {
            let info = SecurityBlockedInfo(error: errorBody)
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.securityBlocked(info)
        }
        if let quotaCode = IMAPIClient.licenseQuotaErrorCode(errorCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: quotaCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: quotaCode,
                message: IMAPIClient.licenseQuotaUserMessage(for: quotaCode),
                error: errorBody
            )
        }
        if Self.isLoginRequestPath(path),
           let loginCode = Self.loginFailureCode(errorCode, statusCode: statusCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: loginCode, requestID: requestID, error: nil)
            throw IMAPIError.loginSecurity(
                code: loginCode,
                message: Self.userMessage(for: errorBody, fallback: "登录失败"),
                info: loginSecurityEnvelope?.data
            )
        }
        // JHT_MOD_BEGIN LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改开始：登录 503 auth_dependency_unavailable 保留业务码，避免被普通 503 吞掉后误回退
        if Self.isLoginRequestPath(path),
           statusCode == 503,
           errorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auth_dependency_unavailable" {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: "auth_dependency_unavailable",
                message: Self.userMessage(for: errorBody, fallback: "登录服务暂不可用，请稍后重试"),
                error: errorBody
            )
        }
        // JHT_MOD_END LOGIN_AUTH_DEPENDENCY_NO_FALLBACK_20260913 - 修改结束
        if statusCode == 401, bearerPurpose == .rtc {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode.isEmpty ? "rtc_unauthorized" : errorCode, requestID: requestID, error: nil)
            throw RTCCredentialError.unauthorized(Self.userMessage(for: errorBody, fallback: "RTC 凭证已失效"))
        }
        // JHT_MOD_BEGIN PUBLIC_MEDIA_GA_COMPAT_AUTH_ERRORS - 修改开始：媒体公共接口的 401/403/423 不触发会话刷新、设备吊销或登录安全分支
        if bearerPurpose == .publicMedia,
           statusCode == 401 || statusCode == 403 || statusCode == 423 {
            let publicMediaCode = Self.effectiveErrorCode(for: errorBody) ?? "http_\(statusCode)"
            logRequestFailure(
                method: method,
                url: url,
                statusCode: statusCode,
                errorCode: publicMediaCode,
                requestID: requestID,
                error: nil
            )
            throw IMAPIError.httpStatus(
                statusCode,
                message: Self.userMessage(
                    for: errorBody,
                    fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)
                )
            )
        }
        // JHT_MOD_END PUBLIC_MEDIA_GA_COMPAT_AUTH_ERRORS - 修改结束
        if bearerPurpose == .session,
           (statusCode == 401 || statusCode == 403),
           DeviceRevocationDetector.matches(error: errorBody) {
            let deviceCode = Self.effectiveErrorCode(for: errorBody) ?? "device_revoked"
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: deviceCode, requestID: requestID, error: nil)
            if Self.isPushDeviceRegistrationRequestPath(path, method: method) {
                throw IMAPIError.businessForbidden(
                    code: deviceCode,
                    message: Self.userMessage(for: errorBody, fallback: "推送设备注册失败"),
                    error: errorBody
                )
            }
            NotificationCenter.default.post(name: .imCurrentDeviceRevoked, object: nil)
            throw IMAPIError.unauthorized(DeviceRevocationDetector.logoutMessage)
        }
        if statusCode == 401, Self.isSessionRefreshRequestPath(path), !errorCode.isEmpty {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMSessionRefreshRejectionError(
                statusCode: statusCode,
                code: errorCode,
                userMessage: Self.userMessage(for: errorBody, fallback: "登录已失效")
            )
        }
        if statusCode == 401 {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "unauthorized", requestID: requestID, error: nil)
            throw IMAPIError.unauthorized(Self.userMessage(for: errorBody, fallback: "登录已失效"))
        }
        if statusCode == 423 {
            let lockedCode = Self.effectiveErrorCode(for: errorBody) ?? "account_locked"
            let lockedMessage = Self.userMessage(for: errorBody, fallback: "账号已锁定，请联系商户后台管理员解锁")
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: lockedCode, requestID: requestID, error: nil)
            throw IMAPIError.loginSecurity(
                code: lockedCode,
                message: lockedMessage,
                info: loginSecurityEnvelope?.data
            )
        }
        if let capabilityCode = Self.licenseCapabilityErrorCode(errorCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: capabilityCode, requestID: requestID, error: nil)
            throw IMAPIError.conflict(
                code: capabilityCode,
                message: Self.userMessage(for: errorBody, fallback: "企业能力不可用")
            )
        }
        if Self.isAccessDiscoveryRequestPath(path),
           Self.isTerminalAccessDiscoveryErrorCode(errorCode) {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: errorCode, requestID: requestID, error: nil)
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: Self.userMessage(for: errorBody, fallback: "实时连接入口暂不可用"),
                error: errorBody
            )
        }
        if statusCode == 403 {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "forbidden", requestID: requestID, error: nil)
            if let errorBody,
               Self.isFriendshipRequiredError(errorBody) {
                throw IMAPIError.businessForbidden(
                    code: Self.effectiveErrorCode(for: errorBody) ?? "not_friends",
                    message: Self.userMessage(for: errorBody, fallback: "需先添加好友后才能发起私聊"),
                    error: errorBody
                )
            }
            if let errorBody {
                throw IMAPIError.businessForbidden(
                    code: Self.effectiveErrorCode(for: errorBody) ?? "forbidden",
                    message: Self.userMessage(for: errorBody, fallback: "无权限"),
                    error: errorBody
                )
            }
            throw IMAPIError.forbidden(Self.userMessage(for: errorBody, fallback: "无权限"))
        }
        if method == "POST", path == "/api/im/conversations/page",
           statusCode == 400 || statusCode == 410 || (500...599).contains(statusCode) {
            throw ConversationPageFailure(
                statusCode: statusCode,
                code: errorCode == "conversation_page_cursor_expired" ? errorCode : "conversation_page_unavailable"
            )
        }
        if preserveRTCSignalErrorDetails,
           (statusCode == 404 || statusCode == 409 || statusCode == 422 ||
            (statusCode == 400 && errorCode == "bad_json" && method == "POST" &&
             path.hasPrefix("/api/rtc/rooms/") && path.hasSuffix("/quality-samples") &&
             path.split(separator: "/").count == 5)) {
            let code = errorCode.isEmpty ? "http_\(statusCode)" : errorCode
            let message = Self.userMessage(
                for: errorBody,
                fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
            logRequestFailure(
                method: method,
                url: url,
                statusCode: statusCode,
                errorCode: code,
                requestID: requestID,
                error: nil
            )
            throw RTCVideoSignalHTTPError(statusCode: statusCode, code: code, message: message)
        }
        if statusCode == 409 {
            let conflictCode = Self.effectiveErrorCode(for: errorBody) ?? "conflict"
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: conflictCode, requestID: requestID, error: nil)
            throw IMAPIError.conflict(
                code: conflictCode,
                message: Self.userMessage(for: errorBody, fallback: "操作冲突")
            )
        }
        if statusCode == 429 {
            let retryAfterHeader = rawResult.retryAfterSeconds
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "rate_limited", requestID: requestID, error: nil)
            throw IMAPIError.rateLimited(
                code: Self.effectiveErrorCode(for: errorBody) ?? "rate_limited",
                message: Self.userMessage(for: errorBody, fallback: "操作过于频繁，请稍后再试"),
                retryAfterSeconds: errorBody?.retryAfterSeconds ?? retryAfterHeader,
                lockedUntil: errorBody?.lockedUntil
            )
        }
        if classifyUncertainRegistrationOutcome,
           (400..<500).contains(statusCode),
           !errorCode.isEmpty {
            let message = Self.userMessage(
                for: errorBody,
                fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
            logRequestFailure(
                method: method,
                url: url,
                statusCode: statusCode,
                errorCode: errorCode,
                requestID: requestID,
                error: nil
            )
            throw IMAPIError.businessForbidden(
                code: errorCode,
                message: message,
                error: errorBody
            )
        }
        if preserveHTTPStatusErrors, !(200..<300).contains(statusCode) {
            if classifyUncertainRegistrationOutcome,
               (errorBody == nil || errorCode.isEmpty) {
                throw RegistrationOutcomeUncertainError()
            }
            let message = Self.userMessage(for: errorBody, fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode))
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: errorBody) ?? "http_\(statusCode)", requestID: requestID, error: nil)
            throw IMAPIError.httpStatus(statusCode, message: message)
        }
        guard let envelope else {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: "decode_envelope_failed", requestID: requestID, error: nil)
            if !errorCode.isEmpty {
                SyncFailureDiagnostic.httpObservation?.recordUploadFailure(AttachmentUploadFailure(
                    code: (200..<300).contains(statusCode) ? .decode : .http,
                    httpStatus: statusCode, serverCode: errorCode
                ))
            }
            if classifyUncertainMessageSendOutcome, (200..<300).contains(statusCode) {
                throw MessageSendOutcomeUncertainError()
            }
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw IMAPIError.server(HTTPURLResponse.localizedString(forStatusCode: statusCode))
        }
        if !(200..<300).contains(statusCode) || envelope.ok == false {
            logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: Self.effectiveErrorCode(for: envelope.error) ?? "api_error", requestID: requestID, error: nil)
            if classifyUncertainRegistrationOutcome {
                throw RegistrationOutcomeUncertainError()
            }
            throw IMAPIError.server(Self.userMessage(for: envelope.error, fallback: HTTPURLResponse.localizedString(forStatusCode: statusCode)))
        }
        if let data = envelope.data {
#if DEBUG
            if observesRegistration {
                registrationDiagnostic = .httpResponse(
                    isSubmission: classifyUncertainRegistrationOutcome,
                    statusCode: statusCode,
                    acceptedPayload: envelope.ok == true,
                    confirmationStatus: (data as? RemoteRegistrationConfirmation)?.status
                )
            }
#endif
            return data
        }
        if T.self == EmptyPayload.self, let empty = EmptyPayload() as? T {
            return empty
        }
        logRequestFailure(method: method, url: url, statusCode: statusCode, errorCode: "empty_data", requestID: requestID, error: nil)
        if classifyUncertainMessageSendOutcome, (200..<300).contains(statusCode) {
            throw MessageSendOutcomeUncertainError()
        }
        if classifyUncertainRegistrationOutcome {
            throw RegistrationOutcomeUncertainError()
        }
        throw IMAPIError.emptyResponse
    }

    static func isSessionRefreshRequestPath(_ path: String) -> Bool {
        let requestPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return requestPath == "/api/platform/auth/session/refresh"
            || requestPath.hasPrefix("/api/platform/tenants/") && requestPath.hasSuffix("/session/refresh")
            || requestPath == "/api/tenant/auth/refresh"
            || requestPath == "/api/tenant/auth/session/refresh"
    }

    static func isPushDeviceRegistrationRequestPath(_ path: String, method: String) -> Bool {
        let requestPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "POST"
            && requestPath == "/api/tenant/devices"
    }

    func rawHTTPResult(
        for request: URLRequest,
        dedupeKey: String?,
		propagateTaskCancellation: Bool = false,
		expectedResponseOrigin: URL? = nil
    ) async throws -> RawHTTPResult {
        let httpTransport = self.httpTransport
        if propagateTaskCancellation {
			let result: HTTPTransportResult
			if let expectedResponseOrigin {
				result = try await httpTransport.data(
					for: request,
					rejectingCrossOriginRedirectsFrom: expectedResponseOrigin
				)
			} else {
				result = try await httpTransport.data(for: request)
			}
            return RawHTTPResult(
                data: result.data,
                isHTTPResponse: result.isHTTPResponse,
                statusCode: result.statusCode,
				responseURL: result.responseURL,
                requestID: Self.requestID(from: result),
                retryAfterSeconds: Self.retryAfterSeconds(from: result)
            )
        }
        let claim = inFlightGETRequests.task(for: dedupeKey) {
            Task.detached(priority: .utility) { () throws -> RawHTTPResult in
                let result = try await httpTransport.data(for: request)
                return RawHTTPResult(
                    data: result.data,
                    isHTTPResponse: result.isHTTPResponse,
                    statusCode: result.statusCode,
					responseURL: result.responseURL,
                    requestID: Self.requestID(from: result),
                    retryAfterSeconds: Self.retryAfterSeconds(from: result)
                )
            }
        }
        defer {
            inFlightGETRequests.finish(claim)
        }
        return try await claim.task.value
    }

    func decodeAPIResponse<T: Decodable>(from data: Data) -> DecodedAPIResponse<T> {
        return DecodedAPIResponse(
            errorEnvelope: try? wireCodec.decode(APIErrorEnvelope.self, from: data),
            loginSecurityEnvelope: try? wireCodec.decode(APILoginSecurityEnvelope.self, from: data),
            envelope: try? wireCodec.decode(APIEnvelope<T>.self, from: data)
        )
    }

    nonisolated static func timeoutInterval(for path: String, method: String) -> TimeInterval {
        let normalizedPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedMethod == "GET" else { return 8 }
        if normalizedPath == "/.well-known/wenxintong-app.json"
            || normalizedPath == "/api/app/bootstrap"
            || normalizedPath == "/api/platform/apps/current-policy" {
            return 4
        }
        if normalizedPath == "/api/tenant/files"
            || normalizedPath == "/api/tenant/friends"
            || normalizedPath == "/api/tenant/groups"
            || normalizedPath == "/api/tenant/devices"
            || normalizedPath == "/api/tenant/inbox"
            || normalizedPath == "/api/tenant/user-stickers"
            || normalizedPath == "/api/tenant/sticker-packs"
            || normalizedPath.hasPrefix("/api/tenant/sticker-packs/") {
            return 15
        }
        return 8
    }

    nonisolated static func redactedPathForLog(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    nonisolated static func idempotentGETRequestKey(base: URL, path: String, method: String, bearer: String?, body: [String: Any]?) -> String? {
        guard method.uppercased() == "GET", body == nil else { return nil }
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }
        guard !isClearOnReadGETPath(normalizedPath) else { return nil }
        let bearerKey = bearer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["GET", base.absoluteString, normalizedPath, bearerKey].joined(separator: "\u{1F}")
    }

    nonisolated static func isClearOnReadGETPath(_ path: String) -> Bool {
        let normalized = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return normalized == "/api/rtc/calls/events"
    }

    func logHTTPRequestStart(method: String, url: URL, bodyData: Data?, dedupeKey: String?) {
        guard SyncFailureDiagnostic.friendAcceptance == nil else { return }
#if DEBUG
        guard !Self.isRegistrationSubmissionURL(url) else { return }
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let bodyBytes = bodyData?.count ?? 0
        let bodyText = Self.shouldSuppressFriendEndpointLogBody(method: normalizedMethod, url: url)
            ? ""
            : Self.redactedLogBody(bodyData)
        let dedupeText = dedupeKey == nil ? "none" : "get_inflight"
        print(Self.apiLogDivider(icon: "➡️", title: "REQUEST START"))
        print("[JHT API] ➡️ request_start method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) body_bytes=\(bodyBytes) dedupe=\(dedupeText)")
        if !bodyText.isEmpty {
            print("[JHT API] 📤 request_body method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) json=\(bodyText)")
        }
#endif
    }

    func logHTTPResponse(method: String, url: URL, statusCode: Int, requestID: String?, data: Data, elapsedMS: Int) {
        guard SyncFailureDiagnostic.friendAcceptance == nil else { return }
#if DEBUG
        guard !Self.isRegistrationSubmissionURL(url) else { return }
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let requestIDText = requestID?.isEmpty == false ? requestID! : "none"
        let statusIcon = Self.httpResponseLogIcon(statusCode)
        print(Self.apiLogDivider(icon: statusIcon, title: Self.httpResponseLogTitle(statusCode)))
        print("[JHT API] \(statusIcon) response method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) status=\(statusCode) request_id=\(requestIDText) bytes=\(data.count) elapsed_ms=\(elapsedMS)")
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改开始：真机性能分析期间限制大响应正文日志，避免日志系统放大卡顿
        let responseBodyLog = Self.redactedResponseBodyLog(
            method: normalizedMethod,
            url: url,
            statusCode: statusCode,
            data: data
        )
        if let suppressedReason = responseBodyLog.suppressedReason {
            print("[JHT API] \(statusIcon) response_body_suppressed method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) request_id=\(requestIDText) bytes=\(data.count) reason=\(suppressedReason)")
        } else if !responseBodyLog.bodyText.isEmpty {
            print("[JHT API] \(statusIcon) response_body method=\(normalizedMethod) url=\(Self.redactedURLString(url, redactAllQueryValues: false)) request_id=\(requestIDText) json=\(responseBodyLog.bodyText)")
        }
        // JHT_MOD_END TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改结束
#endif
    }

    nonisolated static func httpResponseLogIcon(_ statusCode: Int) -> String {
        (200..<300).contains(statusCode) ? "✅" : "❌"
    }

    nonisolated static func httpResponseLogTitle(_ statusCode: Int) -> String {
        (200..<300).contains(statusCode) ? "RESPONSE OK" : "RESPONSE ERROR"
    }

    nonisolated static func apiLogDivider(icon: String, title: String) -> String {
        "[JHT API] \(icon) ────────── \(title) ──────────"
    }

    // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改开始：真机性能分析期间限制大响应正文日志，避免日志系统放大卡顿
    nonisolated static func redactedResponseBodyLog(
        method: String,
        url: URL,
        statusCode: Int,
        data: Data
    ) -> (bodyText: String, suppressedReason: String?) {
        if shouldSuppressFriendEndpointLogBody(method: method, url: url) {
            return ("", nil)
        }
        guard (200..<300).contains(statusCode) else {
            return (redactedLogBody(data, maxCharacters: 2_000), nil)
        }
        if shouldSuppressHighVolumeResponseBodyLog(method: method, url: url) {
            return ("", "high_volume_endpoint")
        }
        if data.count > 4_096 {
            return ("", "large_body")
        }
        return (redactedLogBody(data, maxCharacters: 1_500), nil)
    }

    nonisolated static func shouldSuppressHighVolumeResponseBodyLog(method: String, url: URL) -> Bool {
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMethod == "GET" || normalizedMethod == "POST" else { return false }
        switch path {
        case "/api/tenant/org/members",
             "/api/im/conversations/page",
             "/api/im/delivery-ack",
             "/api/im/message-receipts/sync",
             "/api/im/sync",
             "/api/tenant/inbox":
            return true
        default:
            return false
        }
    }
    // JHT_MOD_END TEMP_PERF_ANALYSIS_LIMIT_HTTP_BODY_LOG_20260912 - 修改结束

    nonisolated static func shouldSuppressFriendEndpointLogBody(method: String, url: URL) -> Bool {
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if path == "/api/tenant/friends", normalizedMethod == "GET" {
            return true
        }
        return path.hasPrefix("/api/tenant/friends/")
            && !path.hasPrefix("/api/tenant/friends/applications/")
    }

    nonisolated static func isRegistrationSubmissionURL(_ url: URL) -> Bool {
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return path == "/api/platform/auth/register"
            || path == "/api/platform/auth/register/status"
            || path == "/api/platform/auth/register/session"
    }

    nonisolated static func redactedLogBody(_ data: Data?, maxCharacters: Int = 12_000) -> String {
        guard let data, !data.isEmpty else { return "" }
        let rawText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? ""
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let redacted = redactedSensitiveLogText(trimmed)
        guard redacted.count > maxCharacters else { return redacted }
        let index = redacted.index(redacted.startIndex, offsetBy: maxCharacters)
        return "\(redacted[..<index])...<truncated chars=\(redacted.count)>"
    }

    func logRequestFailure(method: String, url: URL, statusCode: Int?, errorCode: String, requestID: String?, error: Error?) {
        SyncFailureDiagnostic.httpObservation?.record(path: url.path, status: statusCode, code: errorCode)
        // The dedicated accept channel already preserves safe request metadata.
        // Do not also emit its dynamic application path, free text or payload.
        guard SyncFailureDiagnostic.friendAcceptance == nil else { return }
        if let event = SyncFailureDiagnostic.SessionRequestFailure(
            method: method, path: url.path, status: statusCode, code: errorCode,
            requestSummary: requestID.map(Self.diagnosticFingerprint)
        ) {
            SyncFailureDiagnostic.persistSessionRequestFailure(event)
        }
        guard !Self.isRegistrationSubmissionURL(url) else { return }
        let status = statusCode.map(String.init) ?? "none"
        let requestIDText = requestID?.isEmpty == false ? requestID! : "none"
        let errorText = error.map { " error=\(Self.redactedSensitiveLogText($0.localizedDescription))" } ?? ""
        let wsBase = webSocketURL(context: IMAPIContext.load())
            .map { Self.redactedURLString($0, redactAllQueryValues: true) }
            ?? "unavailable"
        print(Self.apiLogDivider(icon: "❌", title: "REQUEST FAILED"))
        print("[JHT API] ❌ request_failed method=\(method) url=\(Self.redactedURLString(url, redactAllQueryValues: true)) status=\(status) code=\(errorCode) request_id=\(requestIDText) platformBase=\(Self.redactedURLString(platformBase, redactAllQueryValues: true)) tenantBase=\(Self.redactedURLString(tenantBase, redactAllQueryValues: true)) imBase=\(Self.redactedURLString(imBase, redactAllQueryValues: true)) wsBase=\(wsBase)\(errorText)")
    }

    nonisolated static func rtcSignalDebug(_ message: @autoclosure () -> String) {
        let value = message()
#if DEBUG
        NSLog("[JHT RTC][API] %@", value)
#endif
        Task {
            await RTCCallDiagnosticLogStore.shared.append(
                category: "API",
                media: Self.rtcSignalMediaLabel(from: value),
                message: value
            )
        }
    }

    nonisolated private static func rtcSignalMediaLabel(from message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("video") || normalized.contains("media=video") || normalized.contains("media_mode=video") {
            return "video"
        }
        if normalized.contains("voice") || normalized.contains("audio") || normalized.contains("media=audio") || normalized.contains("media_mode=audio") {
            return "voice"
        }
        return "unknown"
    }

    nonisolated static func rtcShortDebugID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(4)) + "..." + String(trimmed.suffix(4))
    }

    nonisolated static func rtcDeviceDebugHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "missing" }
        var hash: UInt32 = 2_166_136_261
        for byte in trimmed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    nonisolated static func requestID(from result: HTTPTransportResult) -> String? {
        result.value(forHTTPHeaderField: "X-Request-Id")
            ?? result.value(forHTTPHeaderField: "X-Request-ID")
            ?? result.value(forHTTPHeaderField: "Request-Id")
    }

    static func isLoginRequestPath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "/api/tenant/auth/login"
            || normalized == "/api/platform/auth/im-login"
    }

    static func isAccessDiscoveryRequestPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "/api/tenant/access/v1/endpoints"
    }

    static func isTerminalAccessDiscoveryErrorCode(_ code: String) -> Bool {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "access_discovery_disabled",
             "access_discovery_tenant_mismatch",
             "access_discovery_app_unavailable":
            return true
        default:
            return false
        }
    }

    static func loginFailureCode(_ code: String, statusCode: Int) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownCodes: Set<String> = [
            "bad_request",
            "invalid_credentials",
            "slide_captcha_required",
            "slide_captcha_invalid",
            "account_locked",
            "account_blocked",
            "login_locked",
            "ip_login_blocked",
            "device_blocked",
            "ip_blocked",
            "tenant_blocked",
            "security_policy_denied",
            "security_blocked",
            "account_disabled",
            "tenant_member_disabled",
            "tenant_member_not_found",
            "tenant_service_stopped",
            "tenant_disabled",
            "tenant_service_unavailable",
            "workspace_session_unavailable",
            "default_workspace_unavailable",
            "app_not_found",
            "workspace_identity_unlinked",
            "workspace_not_found",
            "app_tenant_not_bound",
            "ip_not_allowed",
            "device_binding_required",
            "device_not_bound",
            "license_not_started",
            "license_expired",
            "license_inactive",
            "account_password_sync_failed",
            "phone_auth_disabled",
            "token_sign_failed"
        ]
        if knownCodes.contains(normalized) {
            return normalized
        }
        switch statusCode {
        case 400:
            return "bad_request"
        case 401:
            return "invalid_credentials"
        case 423:
            return "account_locked"
        case 429:
            return "ip_login_blocked"
        default:
            return nil
        }
    }

    static func licenseCapabilityErrorCode(_ code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let capabilityCodes: Set<String> = [
            "message_recall_window_exceeded",
            "voice_call_not_enabled",
            "video_call_not_enabled",
            "rtc_license_capabilities_unavailable",
            "rtc_media_config_missing",
            "rtc_ice_config_missing",
            "rtc_turn_config_missing",
            "read_receipts_not_enabled",
            "feature_not_enabled",
            "group_admin_delete_message_not_enabled"
        ]
        return capabilityCodes.contains(normalized) ? normalized : nil
    }

    static func licenseQuotaErrorCode(_ code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "registered_user_quota_exceeded",
             "online_quota_exceeded",
             "online_quota_service_unavailable",
             "group_member_quota_exceeded":
            return normalized
        default:
            return nil
        }
    }

    static func licenseQuotaUserMessage(for code: String) -> String {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "registered_user_quota_exceeded":
            return "当前企业注册用户数已达上限，请联系企业管理员"
        case "online_quota_exceeded":
            return "当前企业在线人数已达上限，请稍后重试或联系企业管理员"
        case "online_quota_service_unavailable":
            return "在线服务暂时不可用，请稍后重试"
        case "group_member_quota_exceeded":
            return "该群人数已达上限，暂时无法加入"
        default:
            return ""
        }
    }

    nonisolated static func retryAfterSeconds(from result: HTTPTransportResult) -> Int? {
        let raw = result.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        if let seconds = Int(raw) {
            return max(0, seconds)
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            return max(0, Int(ceil(date.timeIntervalSinceNow)))
        }
        return nil
    }

    static func userMessage(for error: APIEnvelopeError?, fallback: String) -> String {
        let code = effectiveErrorCode(for: error)
        let backendMessage = [error?.message, error?.reason]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        switch code {
        case "bad_request":
            return "请输入账号和密码"
        case "login_locked":
            return "登录尝试过多，请稍后再试"
        case "invalid_credentials":
            return "账号或密码错误"
        case "slide_captcha_required":
            return "需要完成安全验证后再登录"
        case "slide_captcha_invalid":
            return "安全验证已失效，请重新验证后再登录"
        case "invalid_user_account_format", "invalid_account_format":
            return "账号必须为 5-10 位数字或英文字母"
        case "account_locked":
            return "账号已锁定，请联系商户后台管理员解锁"
        case "account_blocked":
            return "账号因安全策略限制，暂不可登录"
        case "device_blocked":
            return "当前设备暂不可登录"
        case "ip_blocked":
            return "当前网络暂不可登录"
        case "tenant_blocked":
            return "当前企业暂不可访问"
        case "security_policy_denied":
            return "操作被企业安全策略限制"
        case "security_blocked":
            return SecurityBlockedInfo(error: error).userMessage
        case "ip_login_blocked":
            return "今日登录失败次数过多，当前网络已被禁止登录"
        case "account_password_sync_failed":
            return "账号服务暂不可用，请稍后重试"
        case "registered_user_quota_exceeded":
            return licenseQuotaUserMessage(for: "registered_user_quota_exceeded")
        case "online_quota_exceeded":
            return licenseQuotaUserMessage(for: "online_quota_exceeded")
        case "online_quota_service_unavailable":
            return licenseQuotaUserMessage(for: "online_quota_service_unavailable")
        case "group_member_quota_exceeded":
            return licenseQuotaUserMessage(for: "group_member_quota_exceeded")
        case "ip_not_allowed":
            return "当前网络不在企业允许登录范围内"
        case "session_expired":
            return "登录会话已过期，请重新登录"
        case "refresh_token_expired":
            return "登录续期已过期，请重新登录"
        case "session_revoked":
            return "登录会话已失效，请重新登录"
        case "refresh_token_reused":
            return "登录续期凭证异常，请重新登录"
        case "reauth_required":
            return "当前登录状态需要重新验证"
        case "risk_blocked":
            return "访问已被安全策略限制"
        case "global_muted":
            return globalMutedMessageText
        case "group_muted":
            return globalMutedMessageText
        case "group_member_muted":
            return groupMemberMutedMessageText
        case "group_mute_permission_denied":
            return "禁言名单仅群主或管理员可操作"
        case "group_mute_target_role_not_allowed":
            return "群主或管理员不能加入禁言名单"
        case "not_friends":
            return "需先添加好友后才能发起私聊"
        case "friend_not_found":
            return "好友关系已变化，请刷新联系人后重试"
        case "invalid_friend_remark":
            return "好友备注最多 128 个字符"
        case "friend_remark_readback_failed":
            return "备注可能已保存，正在重新确认"
        case "friend_relation_changed":
            return FriendAddPresentation.relationChangedMessage
        case "client_friend_requests_disabled":
            return "当前关系状态已更新，请重试"
        case "blocked_by_me":
            return "你已拉黑对方，无法发送消息"
        case "blocked_by_target", "message_rejected_by_target":
            return "消息已被对方拒收"
        case "workspace_identity_unlinked":
            return "当前账号企业身份未同步，请联系管理员处理"
        case "workspace_switch_disabled":
            return "管理员已关闭企业切换"
        case "account_disabled":
            return "账号已停用，请联系管理员"
        case "tenant_member_disabled":
            return "当前企业成员关系已停用，请切换其他企业"
        case "tenant_member_not_found":
            return "当前企业成员关系不存在，请切换其他企业"
        case "workspace_not_found", "app_tenant_not_bound":
            return "目标企业不存在，请返回企业列表重新选择"
        case "workspace_join_pending":
            return "入企申请等待审批中"
        case "workspace_join_rejected":
            return "入企申请已被拒绝，请联系企业管理员"
        case "workspace_join_approved":
            return "入企申请已通过"
        case "workspace_already_joined":
            return "已加入该企业"
        case "workspace_join_forbidden":
            return "当前账号暂不能申请加入该企业"
        case "workspace_tenant_unresolved":
            return "企业信息暂未同步，请稍后重试"
        case "workspace_directory_unavailable":
            return "企业目录暂不可用，请稍后重试"
        case "workspace_join_conflict":
            return "入企申请状态冲突，请刷新后重试"
        case "workspace_join_bad_request", "bad_workspace_join_request":
            return "入企申请参数不正确，请重新搜索后再试"
        case "tenant_service_stopped":
            return "当前企业已停用，请切换其他企业"
        case "tenant_disabled":
            return "当前企业已停用，请切换其他企业"
        case "workspace_session_unavailable", "tenant_service_unavailable", "default_workspace_unavailable", "app_not_found":
            return "当前企业服务暂不可用，请切换其他企业或稍后重试"
        case "missing_entry_ticket", "invalid_entry_ticket", "entry_ticket_expired", "entry_ticket_replayed", "entry_ticket_audience_mismatch":
            return "企业入口票据校验失败"
        case "group_not_found":
            return "群聊不存在或已删除"
        case "group_create_not_allowed":
            return "管理员已关闭成员建群"
        case "group_join_request_not_found":
            return "入群申请不存在或已失效"
        case "group_unavailable":
            return "群聊不可用"
        case "group_join_forbidden":
            return "无权限处理该入群申请"
        case "permission_denied", "admin_delete_forbidden", "message_admin_delete_forbidden":
            return "无权限删除该消息"
        case "message_not_found", "message_not_visible", "message_invisible":
            return "消息不存在或已不可见"
        case "message_already_deleted":
            return "该消息已删除"
        case "target_user_not_found":
            return "目标用户不存在"
        case "target_user_unavailable":
            return "目标用户状态不可用"
        case "bad_group_join_request":
            return "入群申请参数不正确"
        case "group_join_conflict":
            return "入群申请状态冲突，请刷新后重试"
        case "group_invite_already_processed", "already_processed":
            return "该入群邀请已处理"
        case "invalid_avatar":
            return "头像格式或尺寸不符合要求，请重新选择图片"
        case "file_not_uploaded":
            return "文件还未上传完成，请重新上传后再试"
        case "file_not_found":
            return "文件不存在或已被清理"
        case "file_too_large", "file_size_exceeded":
            return "文件超过大小限制，请压缩后重试"
        case "file_unavailable":
            return "文件不可用或无权限访问"
        case "validation_error":
            return "请求参数不正确，请检查后重试"
        case "provider_rejected", "kyc_auto_failed":
            return realNameVerificationFailedText
        case "avatar_url_unavailable":
            return "头像地址暂不可用，请稍后重试"
        case "tenant_storage_not_configured":
            return "企业暂未配置文件存储，请联系管理员"
        case "tenant_storage_resource_unavailable":
            return "企业存储资源暂不可用，请联系管理员"
        case "tenant_storage_provider_unsupported":
            return "当前存储服务暂不支持上传"
        case "tenant_storage_secret_unresolved":
            return "企业存储配置未生效，请联系管理员"
        case "rtc_media_config_missing", "rtc_ice_config_missing", "rtc_turn_config_missing":
            return rtcCapabilityFailureMessage(code: code ?? "", media: .generic)
                ?? "通话媒体服务配置缺失，请联系管理员"
        case "rtc_video_not_supported":
            return "当前仅支持语音通话"
        case "rtc_group_call_not_supported":
            return "暂不支持群语音通话"
        case "duplicate_call":
            return "已有进行中的语音呼叫，请勿重复发起"
        case "caller_busy":
            return "你正在通话中，请结束后再试"
        case "callee_busy":
            return "对方正在通话中"
        case "rtc_call_not_found":
            return "通话不存在或已结束"
        case "rtc_call_forbidden":
            return "无权限操作该通话"
        case "rtc_call_not_ringing":
            return "该通话已不在待接听状态"
        case "rtc_call_not_active":
            return "该通话已结束"
        case "message_recall_window_exceeded":
            return "已超过当前企业最长时间"
        case "voice_call_not_enabled", "video_call_not_enabled", "rtc_license_capabilities_unavailable":
            return rtcCapabilityFailureMessage(code: code ?? "", media: .generic) ?? "当前企业未开通通话"
        case "read_receipts_not_enabled":
            return "当前企业未开通"
        case "feature_not_enabled", "group_admin_delete_message_not_enabled":
            return "当前企业未开通"
        case "mention_all_forbidden":
            return "仅群主或管理员可以 @所有人"
        case "message_pin_forbidden":
            return messagePinForbiddenText
        case "message_forward_unsupported":
            return "该消息类型暂不支持转发"
        case "request_identity_mismatch":
            return "当前登录身份与请求不匹配，请重新登录后再试"
        case "group_announcement_forbidden":
            return "无权限查看或处理该群公告"
        case "group_member_required":
            return "仅群成员可以查看该群公告"
        case "group_announcement_disabled":
            return "群公告功能暂不可用"
        case "group_announcement_not_found":
            return "群公告不存在或已失效"
        case "group_announcement_revision_conflict":
            return "公告已被其他管理员更新，请核对后重试"
        case "invalid_group_announcement":
            return "群公告内容不符合要求"
        case "invalid_group_description":
            return "群描述不能超过 500 个字符"
        case "friend_application_cancel_forbidden":
            return "仅申请发起者可取消该好友申请"
        case "friend_application_not_found":
            return "好友申请不存在或已失效"
        case "friend_application_terminal":
            return "好友申请状态已变化，请查看最新状态"
        case "group_owner_transfer_bad_request":
            return "群主转让参数不正确，请重试"
        case "group_owner_transfer_forbidden":
            return "仅当前群主可以转让群主"
        case "group_owner_transfer_target_not_found":
            return "目标成员已不在群内，请刷新后重试"
        case "group_owner_transfer_conflict":
            return "群主状态已变化，请刷新后重试"
        case "announcement_content_required":
            return "请输入公告内容"
        case "tenant_code_required":
            return "请输入企业编码或邀请码"
        case "entry_code_invalid":
            return "请输入有效的企业编码或邀请码"
        case "tenant_code_not_found":
            return "该企业不存在"
        case "identity_prefix_conflict", "enterprise_code_conflict":
            return "企业身份编码发生冲突，请联系平台管理员"
        case "identity_prefix_locked":
            return "企业身份前缀已锁定，请联系平台管理员"
        case "user_id_namespace_exhausted", "user_id_idempotency_conflict":
            return "用户身份暂无法分配，请稍后重试或联系管理员"
        case "member_invite_code_generation_exhausted":
            return "邀请码暂无法生成，请稍后重试或联系管理员"
        case "registration_tenant_code_probe_rate_limited":
            return "企业编码或邀请码验证次数过多，请稍后再试"
        case "enterprise_code_search_rate_limited", "tenant_code_search_rate_limited":
            return "搜索次数过多请晚点再试"
        case "client_registration_rate_limited":
            return "注册用户今日已达上限"
        case "rate_limit_unavailable":
            return "服务繁忙，请稍后重试"
        case "default_tenant_not_configured":
            return "默认商户未配置，请联系管理员"
        case "default_tenant_unavailable":
            return "默认商户不可用，请联系管理员"
        case "captcha_config_missing",
             "captcha_scene_disabled",
             "captcha_scene_not_enabled",
             "captcha_channel_unavailable",
             "tenant_not_found",
             "sms_provider_not_configured",
             "invalid_sms_template",
             "captcha_scene_required",
             "invalid_captcha_channel",
             "rate_limited",
             "captcha_request_rate_limited",
             "captcha_request_cooldown",
             "captcha_device_proof_required",
             "invalid_captcha_request_limit",
             "invalid_captcha_cooldown",
             "captcha_invalid",
             "captcha_expired",
             "token_sign_failed":
            return captchaUserMessage(code: code, reason: backendMessage, fallback: "验证码服务暂不可用")
        case "forbidden":
            return Self.sanitizeBackendMessage(backendMessage ?? "", fallback: "无权限执行该操作")
        default:
            return Self.sanitizeBackendMessage(backendMessage ?? "", fallback: fallback)
        }
    }

    static func isNoCurrentGroupAnnouncementMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized.contains("group_announcement_not_found")
            || normalized.contains("announcement_not_found")
            || normalized.contains("not found")
            || normalized.contains("不存在")
            || normalized.contains("已失效")
            || normalized.contains("暂无")
    }

    static func effectiveErrorCode(for error: APIEnvelopeError?) -> String? {
        let code = error?.code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let reasonCode = error?.reasonCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let genericCodes: Set<String> = ["", "not_found", "bad_request", "forbidden", "conflict", "api_error"]
        if !reasonCode.isEmpty, genericCodes.contains(code) {
            return reasonCode
        }
        if !code.isEmpty {
            return code
        }
        return reasonCode.isEmpty ? nil : reasonCode
    }

    static func isFriendshipRequiredError(_ error: APIEnvelopeError) -> Bool {
        let combined = [
            error.code,
            error.reasonCode,
            error.reason,
            error.message
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        return combined.contains("not_friends")
            || combined.contains("friendship_required")
            || combined.contains("需先添加好友")
    }

    static func sanitizeBackendMessage(_ message: String, fallback: String) -> String {
        BackendUserMessageSanitizer.sanitize(message, fallback: fallback)
    }
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    func urlPathSegmentEncoded() throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw IMAPIError.badURL("invalid path segment")
        }
        return encoded
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

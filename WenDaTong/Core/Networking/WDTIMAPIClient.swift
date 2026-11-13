import Foundation
import CryptoKit
import Dispatch
import IM4Data // WDT_IOS1_HTTP_ROUTE_V5_20261113

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    private let rejectsRedirects: Bool

    init(progress: @escaping @Sendable (Double) -> Void, rejectsRedirects: Bool = false) {
        self.progress = progress
        self.rejectsRedirects = rejectsRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(rejectsRedirects ? nil : request)
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

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
struct MessageSendOutcomeUncertainError: Error {
    var requiresReadback = false
    var statusCode: Int? = nil
    var businessCode: String? = nil
}

@MainActor
final class IMDurableOutgoingSend {
    @TaskLocal static var current: IMDurableOutgoingSend?
    let clientMessageID: String
    let checkScope: (IMAuthSessionFence?) throws -> Void
    private let prepareOutgoing: @Sendable (Bool, Bool) async throws -> LocalMessageSendAdmission
    let deferKnownUnsent: @Sendable () async throws -> Void
    let releaseUnsent: @Sendable () async -> Void
    private(set) var didReserve = false

    init(clientMessageID: String, checkScope: @escaping (IMAuthSessionFence?) throws -> Void,
         prepare: @escaping @Sendable (Bool, Bool) async throws -> LocalMessageSendAdmission,
         deferKnownUnsent: @escaping @Sendable () async throws -> Void,
         releaseUnsent: @escaping @Sendable () async -> Void) {
        self.clientMessageID = clientMessageID
        self.checkScope = checkScope
        self.prepareOutgoing = prepare
        self.deferKnownUnsent = deferKnownUnsent
        self.releaseUnsent = releaseUnsent
    }

    func prepare(selectedV5: Bool, protect: Bool) async throws -> LocalMessageSendAdmission {
        let admission = try await prepareOutgoing(selectedV5, protect)
        if case .send = admission, protect { didReserve = true }
        return admission
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

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
        let producerSourceCorrelation: UInt64? // WDT_IOS1_SDK_GET_V3_20261111: diagnostic only, not wire/authority.
    }

    struct DecodedAPIResponse<T: Decodable>: @unchecked Sendable {
        let errorEnvelope: APIErrorEnvelope?
        let loginSecurityEnvelope: APILoginSecurityEnvelope?
        let envelope: APIEnvelope<T>?
    }

    let configuredPlatformBase: URL
    let trustedPreloginPlatformBase: URL?
	private(set) var tenantBase: URL
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
	private(set) var imBase: URL {
        willSet {
            if imBase != newValue { runtimeRouteStore.invalidateOutgoingConfirmation() }
        }
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
    let routeV5NetworkOverride: (@MainActor @Sendable () -> Bool)?
    var routeV5StartupContext: IMAPIContext?
    var activeHTTPRoutesV5: IMRouteV5Coordinator?
    var httpRoutesV5: IMRouteV5Coordinator {
        if let activeHTTPRoutesV5 { return activeHTTPRoutesV5 }
        let coordinator = IMRouteV5Coordinator(store: runtimeRouteStore, networkOverride: routeV5NetworkOverride)
        if let routeV5StartupContext { coordinator.updateSession(routeV5StartupContext) }
        activeHTTPRoutesV5 = coordinator
        return coordinator
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
	var appRouteSnapshot: IMRuntimeRouteSnapshot?
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
	var tenantRouteSnapshot: IMRuntimeRouteSnapshot? {
        willSet {
            if tenantRouteSnapshot != newValue { runtimeRouteStore.invalidateOutgoingConfirmation() }
        }
    }
    var revokedTenantRuntimeScope: (appID: String, tenantID: String)? {
        willSet {
            if revokedTenantRuntimeScope?.appID != newValue?.appID || revokedTenantRuntimeScope?.tenantID != newValue?.tenantID {
                runtimeRouteStore.invalidateOutgoingConfirmation()
            }
        }
    }
    // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
        // WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111_BEGIN
        startupContext: IMAPIContext? = nil,
        // WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111_END
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
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        routeV5NetworkOverride = bootstrapNetworkReachable
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
		// WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111_BEGIN
		let storedContext = startupContext ?? IMAPIContext.load()
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        routeV5StartupContext = storedContext
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
		// WDT_IOS1_STAGE0_SNAPSHOT_API_STARTUP_CONTEXT_20261111_END
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
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
            let scope = IMRouteV5Scope(appID: appID, environment: environment, tenantID: nil, service: "public_bootstrap")
            let usesPublicV5 = trustedPreloginPlatformBase == nil && runtimeRouteStore.routeV5Enabled(scope.service)
            let publicAuthority = usesPublicV5 ? runtimeRouteStore.record(appID: appID, tenantID: nil) : nil
            if usesPublicV5 {
                if ["disabled", "tombstone"].contains(publicAuthority?.publicationWatermark?.status ?? "") { return }
                if let receipt = runtimeRouteStore.publicBootstrapReceipt(scope: scope) {
                    restorePublicBootstrap(receipt, scope: scope, packaged: packagedBootstrapHostConfiguration)
                    return
                }
            }
            // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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
               publicAuthority?.current.map({
                   $0.revision == cached.bootstrap.routeRevision && $0.configHash == cached.bootstrap.configHash
               }) != false, // WDT_IOS1_HTTP_ROUTE_V5_20261113
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

    static func friendProfilePath(canonicalFriendUID: String) throws -> String {
        let normalizedUID = canonicalFriendUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty else {
            throw IMAPIError.missingContext("friend_uid")
        }
        return "/api/tenant/friends/\(try normalizedUID.urlPathSegmentEncoded())"
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

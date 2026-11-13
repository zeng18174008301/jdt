import Foundation
import CryptoKit
import Dispatch
import IM4Core // WDT_IOS1_HTTP_ROUTE_V5_20261113

@MainActor
extension IMAPIClient {
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
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        activeHTTPRoutesV5?.invalidate(resetBackoff: false) { $0.tenantID != nil }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
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

    // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_BEGIN
    func recordRuntimeColdLaunchPreferredFailureIfNeeded(
        beganDuringColdLaunch: Bool,
        plan: (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool),
        attemptStartedAtMS: UInt64
    ) {
        let completedMS = runtimeMonotonicNowMS()
        let elapsedMS = completedMS >= attemptStartedAtMS ? completedMS - attemptStartedAtMS : 0
        recordRuntimeColdLaunchFailureIfNeeded(
            beganDuringColdLaunch: beganDuringColdLaunch, plan: plan, qualifiedFailureDurationMS: elapsedMS
        )
    }
    // WDT_IOS1_TYPED_USER_PROFILES_DECODE_20261111_END

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
        preservePercentEncodedPath: Bool,
        requestAuthority: IMAuthSessionFence?
	) {
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
        let usesLegacyProbe: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return path.hasPrefix("/api/rtc/") || !self.runtimeRouteStore.routeV5Enabled(plan.service.rawValue)
        }
        guard usesLegacyProbe() else { return }
        // WDT_IOS1_HTTP_ROUTE_V5_20261113_END
		let stableMS = plan.snapshot.policy.preferredProbeStableMS
		guard preferredHTTPProbeInFlightServices.insert(plan.service).inserted else { return }
		let tenantGeneration: UInt64? = plan.snapshot.tenantID == nil ? nil : tenantRouteTransientGeneration
		// WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111_BEGIN
		// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
		let listRoute = TypedListResponseRoute.matching(method: "GET", path: path, response: T.self)
		let directoryAuthority: (@MainActor @Sendable () -> Bool)? = switch listRoute {
		case .organizationMembers: OrganizationMembersRequestOwner.current?.ownsAuthority
		case .groupDirectory: GroupDirectoryRequestOwner.current?.ownsAuthority
		case .organizationTree: ScopedListRequestOwner.current?.ownsAuthority // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
		default: nil
		}
		let checksDirectoryProbe = directoryAuthority != nil || listRoute == .groupDirectory || listRoute == .organizationTree // WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112
		// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END
		let routeIsCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
			self?.runtimeProbeAuthorityIsCurrent(plan.snapshot, tenantGeneration: tenantGeneration) == true
		}
		let probeIsCurrent: @MainActor @Sendable () -> Bool = {
			routeIsCurrent() && usesLegacyProbe() && (directoryAuthority?() ?? true) // WDT_IOS1_HTTP_ROUTE_V5_20261113
		}
		let runProbe: @MainActor @Sendable () async -> Void = { [weak self] in
			guard let self else { return }
			defer {
				if routeIsCurrent() {
					self.preferredHTTPProbeInFlightServices.remove(plan.service)
				}
			}
			do {
				try await self.runtimeSleep(stableMS)
				for ordinal in 0..<plan.snapshot.policy.preferredProbeSuccesses {
					if ordinal > 0 { try await self.runtimeSleep(plan.snapshot.policy.preferredProbeIntervalMS) }
					guard probeIsCurrent() else { return }
					let _: T = try await self.requestOnce(
						base: base, path: path, method: "GET", bearer: bearer, body: nil,
						additionalHeaders: additionalHeaders, cachePolicy: .reloadIgnoringLocalCacheData,
						preserveHTTPStatusErrors: preserveHTTPStatusErrors,
						preserveRTCSignalErrorDetails: preserveRTCSignalErrorDetails,
						timeoutInterval: TimeInterval(plan.snapshot.policy.preferredFailureBudgetMS) / 1_000,
						bearerPurpose: bearerPurpose,
						propagateTaskCancellation: true,
                        preservePercentEncodedPath: preservePercentEncodedPath,
                        requestAuthority: requestAuthority
					)
					guard usesLegacyProbe(), !checksDirectoryProbe || probeIsCurrent() else { return } // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
					self.runtimeRouteSelector.recordPreferredProbe(
						snapshot: plan.snapshot, service: plan.service, kind: .http,
						succeeded: true, stableMS: stableMS,
						nowMS: self.runtimeMonotonicNowMS()
					)
					guard self.runtimeRouteSelector.recovery(plan.snapshot, service: plan.service).recovery else { return }
				}
			} catch {
				guard probeIsCurrent() else { return }
				if checksDirectoryProbe { // WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111
					if error is CancellationError || Self.runtimeRouteFailure(for: error) == .cancelled { return }
					if case .forcedAuthRequired? = error as? IMAPIError { return }
				}
				self.runtimeRouteSelector.recordPreferredProbe(
					snapshot: plan.snapshot, service: plan.service, kind: .http,
					succeeded: false, stableMS: 0,
					nowMS: self.runtimeMonotonicNowMS()
				)
			}
		}
		// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_BEGIN
		let membersProbeOwner = listRoute == .organizationMembers && directoryAuthority != nil
			? OrganizationMembersRequestOwner(ownsRequest: probeIsCurrent, ownsAuthority: probeIsCurrent)
			: OrganizationMembersRequestOwner.current
		let groupProbeOwner = listRoute == .groupDirectory
			? GroupDirectoryRequestOwner(ownsRefresh: routeIsCurrent, ownsAuthority: probeIsCurrent)
			: GroupDirectoryRequestOwner.current
		// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
		let treeProbeOwner = listRoute == .organizationTree && directoryAuthority != nil
			? ScopedListRequestOwner(ownsRequest: probeIsCurrent, ownsAuthority: probeIsCurrent)
			: ScopedListRequestOwner.current
		// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
		// Bind before creating the Task so it inherits the probe authority without the refresh ID.
		OrganizationMembersRequestOwner.$current.withValue(membersProbeOwner) {
			GroupDirectoryRequestOwner.$current.withValue(groupProbeOwner) {
				// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_BEGIN
				ScopedListRequestOwner.$current.withValue(treeProbeOwner) {
					_ = Task(operation: runProbe)
				}
				// WDT_IOS1_TYPED_ORG_TREE_FAVORITE_ASSETS_DECODE_20261112_END
			}
		}
		// WDT_IOS1_GROUP_DIRECTORY_OWNER_FENCE_20261111_END
		// WDT_IOS1_ORG_MEMBERS_PREFERRED_PROBE_AUTHORITY_20261111_END
		_ = responseType
	}
}

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
@MainActor
extension IMAPIClient {
    func updateHTTPRouteSession(_ context: IMAPIContext) {
        if routeV5StartupContext?.authSessionFence != context.authSessionFence
            || routeV5StartupContext?.imToken != context.imToken
            || routeV5StartupContext?.imAPIBaseURL != context.imAPIBaseURL {
            runtimeRouteStore.invalidateOutgoingConfirmation()
        }
        routeV5StartupContext = context
        activeHTTPRoutesV5?.updateSession(context)
    }

    private enum HTTPRouteRead: Sendable {
        case platform(String)
        case tenant(app: String, tenant: String, user: String, device: String)
        case messages(channel: String, channelType: String, limit: Int)

        enum Validation { case verified, incomplete, rejected }

        func validation(of result: Any) -> Validation {
            switch self {
            case .platform(let app):
                guard let policy = result as? RemoteAppCurrentPolicy else { return .incomplete }
                return policy.appID == app && policy.platform.lowercased() == "ios" && policy.isUsable
                    ? .verified : .rejected
            case .tenant(let app, let tenant, let user, let device):
                guard let context = result as? RemoteTenantContext else { return .incomplete }
                return context.appID == app && context.tenantID == tenant && context.imUID == user
                    && context.deviceID == device ? .verified : .rejected
            case .messages(let channel, let channelType, let limit):
                guard let page = result as? RemoteMessageSyncResult, page.hasExplicitItems else { return .incomplete }
                guard page.items.allSatisfy({ $0.channelID == channel && $0.channelType == channelType }) else {
                    return .rejected
                }
                return page.items.count <= limit && page.items.allSatisfy({ $0.channelSeq > 0 })
                    ? .verified : .incomplete
            }
        }
    }

    private func httpRouteRead(
        service: IMRuntimeRouteService, snapshot: IMRuntimeRouteSnapshot, path: String,
        method: String, bearer: String?, body: [String: Any]?, session: IMAPIContext?,
        authority: IMAuthSessionFence?
    ) -> HTTPRouteRead? {
        let components = URLComponents(string: path)
        if service == .platformAPI, method == "GET", bearer == nil,
           components?.path == "/api/platform/apps/current-policy",
           components?.queryItems?.first(where: { $0.name == "app_id" })?.value == snapshot.appID {
            return .platform(snapshot.appID)
        }
        guard let session, authority == session.authSessionFence, session.hasIMSession,
              snapshot.appID == session.appID, let tenant = session.tenantID, tenant == snapshot.tenantID,
              let user = session.imUID, bearer == session.imToken else { return nil }
        if service == .tenantAPI, method == "GET", path == "/api/tenant/context" {
            return .tenant(app: snapshot.appID, tenant: tenant, user: user, device: session.deviceID)
        }
        if service == .imAPI, method == "POST", path == "/api/im/sync",
           let body, let limit = body["limit"] as? Int, (1...10).contains(limit),
           body["tenant_id"] as? String == tenant, body["app_id"] as? String == snapshot.appID,
           body["im_uid"] as? String == user, body["device_id"] as? String == session.deviceID,
           let channel = body["channel_id"] as? String, !channel.isEmpty,
           let channelType = body["channel_type"] as? String, !channelType.isEmpty {
            return .messages(channel: channel, channelType: channelType, limit: limit)
        }
        return nil
    }

    func requestUsingHTTPRouteV5<T: Decodable>(
        base: URL, snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, path: String,
        method: String, bearer: String?, body: [String: Any]?, requestAuthority: IMAuthSessionFence?,
        contactOwner: ContactHTTPRequestOwner?,
        send: (URL, @escaping @MainActor () throws -> Void) async throws -> T
    ) async throws -> T {
        guard let endpoints = snapshot.services[service.rawValue] else { throw CancellationError() }
        let signedBase = service == .platformAPI ? trustedPreloginPlatformBase : nil
        let authorized = signedBase.map { [$0] } ?? (endpoints.preferred + endpoints.backups).compactMap(URL.init(string:))
        // Explicit bases outside this snapshot belong to their caller's own authority.
        guard signedBase != nil || authorized.contains(where: {
            Self.sameOrigin($0, base) && ($0.path == base.path || ["", "/"].contains(base.path))
        }) else {
            return try await send(base) { try Task.checkCancellation() }
        }
        let routes = httpRoutesV5
        let scope = IMRouteV5Scope(appID: snapshot.appID,
            environment: snapshot.environment ?? Self.configuredAppBootstrapEnvironment(),
            tenantID: snapshot.tenantID, service: service.rawValue)
        let sessionFence = routes.session?.authSessionFence
        let tenantGeneration = snapshot.tenantID == nil ? nil : tenantRouteTransientGeneration
        let generation = routes.networkGeneration
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.runtimeRouteStore.routeV5Enabled(service.rawValue)
                && self.runtimeProbeAuthorityIsCurrent(snapshot, tenantGeneration: tenantGeneration)
                && (snapshot.tenantID == nil || (routes.session?.tenantID == snapshot.tenantID
                    && routes.session?.appID == snapshot.appID))
                && !self.isTenantRuntimeRevoked(appID: snapshot.appID, tenantID: snapshot.tenantID)
                && routes.session?.authSessionFence == sessionFence
                && (requestAuthority == nil || requestAuthority == sessionFence)
                && contactOwner?.ownsAuthority() != false
        }
        let checkAuthority: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkAuthority()
        guard let endpoint = routes.selected(in: scope, authorized: authorized) else { throw CancellationError() }
        guard let read = httpRouteRead(service: service, snapshot: snapshot, path: path, method: method,
                                       bearer: bearer, body: body, session: routes.session, authority: requestAuthority)
        else {
            return try await send(endpoint, checkAuthority)
        }

        let alternatives = authorized.filter { $0 != endpoint }
        let attempt = IMRouteV5Attempt()
        let readBody = try body.map { try wireCodec.encodeJSONObject($0) }
        let raceIsCurrent: @MainActor @Sendable () -> Bool = {
            attempt.canRace && isCurrent()
                && routes.networkUsable && routes.networkGeneration == generation
                && routes.selected(in: scope, authorized: authorized) == endpoint
        }
        let checkProbeAuthority: @MainActor @Sendable () throws -> Void = {
            try checkAuthority()
            guard raceIsCurrent() else { throw CancellationError() }
        }
        let timer = Task { @MainActor in
            guard !alternatives.isEmpty else { return }
            do {
                try await attempt.waitForDeadline()
                guard attempt.canRace else { return }
                _ = try await routes.race(
                    scope: scope, configuration: snapshot.configHash, networkGeneration: generation,
                    candidates: alternatives, trigger: attempt,
                    isCurrent: raceIsCurrent,
                    probe: { candidate in
                        let payload = try readBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
                        // Speculative responses carry no session-mutation authority.
                        let value: any Sendable
                        switch read {
                        case .platform:
                            let policy: RemoteAppCurrentPolicy = try await self.requestOnce(
                                base: candidate, path: path, cachePolicy: .reloadIgnoringLocalCacheData,
                                requiredHTTPStatus: 200, propagateTaskCancellation: true,
                                expectedResponseOrigin: candidate, validateRTCRequest: checkProbeAuthority, requestAuthority: nil,
                                forcedAuthAuthorityBase: base)
                            value = policy
                        case .tenant:
                            let context: RemoteTenantContext = try await self.requestOnce(
                                base: candidate, path: path, bearer: bearer, cachePolicy: .reloadIgnoringLocalCacheData,
                                requiredHTTPStatus: 200, propagateTaskCancellation: true,
                                expectedResponseOrigin: candidate, validateRTCRequest: checkProbeAuthority, requestAuthority: nil,
                                forcedAuthAuthorityBase: base)
                            value = context
                        case .messages:
                            let page: RemoteMessageSyncResult = try await self.requestOnce(
                                base: candidate, path: path, method: method, bearer: bearer, body: payload,
                                cachePolicy: .reloadIgnoringLocalCacheData, requiredHTTPStatus: 200,
                                propagateTaskCancellation: true, expectedResponseOrigin: candidate,
                                validateRTCRequest: checkProbeAuthority, requestAuthority: nil, forcedAuthAuthorityBase: base)
                            value = page
                        }
                        return read.validation(of: value) == .verified
                    },
                    commit: { candidate, valid in
                        guard valid else { return false }
                        self.runtimeRouteStore.recordSuccessfulRoute(candidate, in: scope)
                        self.recordAccessDiagnosticsRouteHit(service: service, endpoint: candidate,
                            tier: candidate == authorized.first ? .preferred : .backup)
                        return true
                    }
                )
            } catch { }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let value = try await HTTPRouteTiming.$current.withValue(attempt.timing) {
                    try await send(endpoint, checkAuthority)
                }
                let validation = read.validation(of: value)
                if validation == .rejected { attempt.rejectRace() }
                if isCurrent(), routes.networkGeneration == generation,
                   routes.selected(in: scope, authorized: authorized) == endpoint,
                   attempt.latestStatus == 200, validation == .verified {
                    routes.confirmed(endpoint, scope: scope)
                    attempt.recordValidation(service: scope.service)
                    recordAccessDiagnosticsRouteHit(service: service, endpoint: endpoint,
                        tier: endpoint == authorized.first ? .preferred : .backup)
                } else if validation == .incomplete, attempt.hasProvisionalSuccess {
                    await timer.value
                }
                return value
            } catch {
                attempt.finish()
                if attempt.shouldWaitForRace(after: error) {
                    await timer.value
                } else {
                    attempt.rejectRace()
                }
                throw error
            }
        } onCancel: {
            timer.cancel()
        }
    }

    nonisolated static func qualifiesForHTTPRouteV5(_ error: Error) -> Bool {
        switch runtimeRouteFailure(for: error) {
        case .dns, .connect, .timeout, .reset: return true
        default: return false
        }
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

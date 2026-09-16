import Foundation

@MainActor
extension IMAPIClient {
    func myTenantDirectory(platformToken: String?, appID: String) async throws -> RemoteTenantDirectoryResult {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        return try await request(
            base: base,
            path: "/api/platform/me/tenants?app_id=\(normalizedAppID.urlQueryEncoded)",
            bearer: platformToken,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func listMyTenants(platformToken: String?, appID: String) async throws -> [RemoteTenantMembership] {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        let data = try await myTenantDirectory(platformToken: platformToken, appID: normalizedAppID)
        return data.preferredMemberships.filter { $0.isVisibleInAppScope(normalizedAppID) }
    }

    func searchTenant(code: String, platformToken: String?, appID: String) async throws -> RemoteTenant {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let normalizedCode = try Self.normalizedOptionalRegistrationEntryCode(code)
        guard !normalizedCode.isEmpty else {
            throw IMAPIError.businessForbidden(code: "entry_code_invalid", message: "请输入有效的企业编码或邀请码", error: nil)
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        let result: RemoteTenant = try await request(
            base: base,
            path: "/api/platform/tenants/search?tenant_code=\(normalizedCode.urlQueryEncoded)&app_id=\(normalizedAppID.urlQueryEncoded)",
            bearer: platformToken
        )
        return result
    }

    func joinTenant(code: String, platformToken: String?, appID: String) async throws -> RemoteTenantMembership {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let normalizedCode = try Self.normalizedOptionalRegistrationEntryCode(code)
        guard !normalizedCode.isEmpty else {
            throw IMAPIError.businessForbidden(code: "entry_code_invalid", message: "请输入有效的企业编码或邀请码", error: nil)
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        let result: RemoteTenantMembership = try await request(
            base: base,
            path: "/api/platform/tenants/join",
            method: "POST",
            bearer: platformToken,
            body: [
                "tenant_code": normalizedCode,
                "app_id": normalizedAppID
            ]
        )
        return result
    }

    func resolveWorkspaceEntry(entryCode: String, platformToken: String?) async throws -> RemoteWorkspaceEntryState {
        let normalizedCode = try Self.normalizedOptionalRegistrationEntryCode(entryCode)
        guard !normalizedCode.isEmpty else {
            throw IMAPIError.missingContext("entry_code")
        }
        return try await request(
            base: tenantBase,
            path: "/api/tenant/workspace-entry/resolve",
            method: "POST",
            bearer: platformToken,
            body: ["entry_code": normalizedCode]
        )
    }

    @MainActor
    func prepareWorkspaceEntry(
        tenantID: String?,
        entryCode: String?,
        entrySource: String?,
        idempotencyKey: String?,
        platformToken: String?,
        context: IMAPIContext?
    ) async throws -> RemoteWorkspaceEntryState {
        var body: [String: Any] = [:]
        if let tenantID = tenantID?.trimmingCharacters(in: .whitespacesAndNewlines), !tenantID.isEmpty {
            body["tenant_id"] = tenantID
        }
        if let entryCode {
            let normalizedEntryCode = try Self.normalizedOptionalRegistrationEntryCode(entryCode)
            if !normalizedEntryCode.isEmpty {
                body["entry_code"] = normalizedEntryCode
            }
        }
        if let entrySource = entrySource?.trimmingCharacters(in: .whitespacesAndNewlines), !entrySource.isEmpty {
            body["entry_source"] = entrySource
        }
        if let idempotencyKey = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines), !idempotencyKey.isEmpty {
            body["idempotency_key"] = idempotencyKey
        }
        guard !body.isEmpty else {
            throw IMAPIError.missingContext("workspace_entry_target")
        }
        let base = try await preEnterWorkspaceEntryBase(context: context)
        return try await request(
            base: base,
            path: "/api/tenant/workspace-entry/prepare",
            method: "POST",
            bearer: platformToken,
            body: body
        )
    }

    @MainActor
    func workspaceEntryStatus(tenantID: String, platformToken: String?, context: IMAPIContext?) async throws -> RemoteWorkspaceEntryState {
        let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTenantID.isEmpty else {
            throw IMAPIError.missingContext("tenant_id")
        }
        let base = try await preEnterWorkspaceEntryBase(context: context)
        return try await request(
            base: base,
            path: "/api/tenant/workspace-entry/status?tenant_id=\(normalizedTenantID.urlQueryEncoded)",
            bearer: platformToken,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func enterTenant(tenantID: String, platformToken: String?, appID: String, deviceID: String) async throws -> RemoteTenantEnterResult {
        try await enterTenant(tenantID: tenantID, platformToken: platformToken, appID: appID, deviceID: deviceID, installReadyRoutes: true)
    }

    func enterTenantCandidate(tenantID: String, platformToken: String?, appID: String, deviceID: String) async throws -> RemoteTenantEnterResult {
        try await enterTenant(tenantID: tenantID, platformToken: platformToken, appID: appID, deviceID: deviceID, installReadyRoutes: false)
    }

    func commitTenantRuntimeRoutes(_ snapshot: IMRuntimeRouteSnapshot, appID: String, tenantID: String) throws {
        guard let clean = snapshot.validated(appID: appID, tenantID: tenantID) else {
            throw IMAPIError.businessForbidden(code: "route_contract_mismatch", message: "企业服务路由校验失败", error: nil)
        }
        let applied = runtimeRouteStore.applyAuthenticationCandidate(clean, appID: appID, tenantID: tenantID)
        guard applied == .applied || applied == .idempotent else {
            throw IMAPIError.businessForbidden(code: "route_revision_rejected", message: "企业服务路由未能提交", error: nil)
        }
        installValidatedTenantRouteSnapshot(clean)
    }

    func enterTenant(tenantID: String, platformToken: String?, appID: String, deviceID: String, installReadyRoutes: Bool) async throws -> RemoteTenantEnterResult {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        let base = try await platformAPIBase(appID: normalizedAppID)
#if DEBUG
        recordWorkspaceEntryDiagnosticSummary(
            "enter_request path=/api/platform/me/tenants/{tenant}/enter app_id=\(normalizedAppID) device=\(Self.debugDiagnosticFingerprint(deviceID))"
        )
#endif
        let result: RemoteTenantEnterResult = try await request(
            base: base,
            path: "/api/platform/me/tenants/\(tenantID.urlPathEncoded)/enter",
            method: "POST",
            bearer: platformToken,
            body: [
                "app_id": normalizedAppID,
                "device_id": deviceID,
                "client_type": "ios",
                "requested_capabilities": ["im_realtime"]
            ]
        )
		guard result.runtimeConfig.contractVersion == 2 else {
			throw IMAPIError.businessForbidden(code: "route_contract_required", message: "企业路由契约版本无效", error: nil)
		}
		let snapshot = result.runtimeConfig.runtimeRouteSnapshot
		if ["disabled", "tombstone"].contains(snapshot.publicationStatus ?? "") {
            guard let environment = snapshot.environment,
                  let revision = snapshot.publicationRevision,
                  let publicationID = snapshot.publicationID,
                  let fingerprint = snapshot.profileFingerprint,
                  let keysetRevision = snapshot.keysetRevision else {
                throw IMAPIError.businessForbidden(code: "route_contract_mismatch", message: "企业路由撤销合同不完整", error: nil)
            }
            let revoked = runtimeRouteStore.applyRevocation(
                environment: environment,
                appID: normalizedAppID,
                tenantID: tenantID,
                revision: revision,
                publicationID: publicationID,
                profileFingerprint: fingerprint,
                status: snapshot.publicationStatus ?? "",
                keysetRevision: keysetRevision
            )
            guard revoked == .revoked || revoked == .idempotent else {
                throw IMAPIError.businessForbidden(code: "route_revision_rejected", message: "企业路由撤销版本已拒绝", error: nil)
            }
            revokedTenantRuntimeScope = (normalizedAppID, tenantID)
            tenantRouteSnapshot = nil
            throw IMAPIError.businessForbidden(code: "tenant_service_stopped", message: "企业服务已停用", error: nil)
        }
		guard let clean = snapshot.validated(appID: normalizedAppID, tenantID: tenantID) else {
			let failureCode: String
			if snapshot.appID != normalizedAppID || snapshot.tenantID != tenantID {
				failureCode = snapshot.appID != normalizedAppID ? "app_context_mismatch" : "route_tenant_mismatch"
			} else if snapshot.recomputedConfigHash != snapshot.configHash {
				failureCode = "route_hash_mismatch"
			} else {
				failureCode = "route_contract_mismatch"
			}
			throw IMAPIError.businessForbidden(code: failureCode, message: "企业服务路由校验失败", error: nil)
		}
		guard installReadyRoutes else { return result }
		let applied = runtimeRouteStore.apply(clean, appID: normalizedAppID, tenantID: tenantID)
		guard applied == .applied || applied == .idempotent else {
			throw IMAPIError.businessForbidden(code: "route_revision_rejected", message: "企业服务路由版本已拒绝", error: nil)
		}
		installValidatedTenantRouteSnapshot(clean)
		return result
    }

	func activeRuntimeBase(service: IMRuntimeRouteService, appID: String, tenantID: String?) -> URL? {
        if service != .platformAPI, isTenantRuntimeRevoked(appID: appID, tenantID: tenantID) { return nil }
		let snapshot = service == .platformAPI ? appRouteSnapshot : tenantRouteSnapshot
		guard let snapshot, snapshot.appID == appID, snapshot.tenantID == tenantID,
		      let raw = runtimeRouteSelector.endpoints(snapshot, service: service).first else { return nil }
		return URL(string: raw)
	}

	func runtimeTenantBinaryRouteContext(context: IMAPIContext) -> IMRuntimeTenantBinaryRouteContext? {
		guard let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
		      let snapshot = tenantRouteSnapshot,
		      snapshot.appID == context.appID,
		      snapshot.tenantID == tenantID else { return nil }
		let tiers = runtimeRouteSelector.endpointTiers(snapshot, service: .tenantAPI)
		let active = tiers.preferred.compactMap(URL.init(string:))
		let standby = tiers.backups.compactMap(URL.init(string:))
		guard !active.isEmpty || !standby.isEmpty else { return nil }
		return .init(
			appID: snapshot.appID,
			tenantID: tenantID,
			revision: snapshot.revision,
			activeBases: active,
			standbyBases: standby,
			recovery: runtimeRouteSelector.recovery(snapshot, service: .tenantAPI).recovery
		)
	}

	func fetchRuntimeTenantBinary(
		_ rawValue: String,
		context: IMAPIContext,
		cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
	) async throws -> IMRuntimeTenantBinaryFetchResult {
		let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, let parsed = URL(string: trimmed) else {
			throw IMRuntimeTenantBinaryFetchError.invalidRelativePath
		}
		let relativePath = runtimeTenantRelativeBinaryPath(parsed)
		guard let relativePath else {
			guard parsed.scheme?.lowercased() == "https" || (Self.allowsRuntimeAPIBaseOverride && parsed.scheme?.lowercased() == "http") else {
				throw IMRuntimeTenantBinaryFetchError.invalidRelativePath
			}
			let direct = try await fetchRuntimeTenantBinaryOnce(
				url: parsed,
				timeoutInterval: Self.timeoutInterval(for: parsed.path, method: "GET"),
				cachePolicy: cachePolicy
			)
			guard (200..<300).contains(direct.statusCode) else {
				throw IMRuntimeTenantBinaryFetchError.httpStatus(direct.statusCode)
			}
			return direct
		}
		guard let plan = runtimeRoutePlan(base: tenantBase(for: context), path: relativePath),
		      plan.service == .tenantAPI else {
			throw IMRuntimeTenantBinaryFetchError.routeUnavailable
		}
		let beganDuringColdLaunch = runtimeColdLaunchLifecycle.isTracking
		let startedMS = runtimeMonotonicNowMS()
		let budgetMS = plan.snapshot.policy.preferredFailureBudgetMS
		let deadlineMS = startedMS > UInt64.max - budgetMS ? UInt64.max : startedMS + budgetMS
		var lastQualifiedError: Error?
		for endpoint in plan.primary {
			guard let base = URL(string: endpoint),
			      let url = Self.resolvedURL(base: base, path: relativePath) else { continue }
			let nowMS = runtimeMonotonicNowMS()
			guard nowMS < deadlineMS else { break }
			do {
				let result = try await fetchRuntimeTenantBinaryOnce(
					url: url,
					timeoutInterval: TimeInterval(deadlineMS - nowMS) / 1_000,
					cachePolicy: cachePolicy
				)
				guard (200..<300).contains(result.statusCode) else {
					throw IMRuntimeTenantBinaryFetchError.httpStatus(result.statusCode)
				}
				recordRuntimeColdLaunchSuccessIfNeeded(beganDuringColdLaunch: beganDuringColdLaunch, plan: plan)
				if plan.recovery, let preferred = plan.backups.first.flatMap(URL.init(string:)) {
					schedulePreferredTenantBinaryProbe(base: preferred, path: relativePath, cachePolicy: cachePolicy, plan: plan)
				}
				return result
			} catch {
				let failure: IMRuntimeRouteFailure
				if case let IMRuntimeTenantBinaryFetchError.httpStatus(status) = error { failure = .http(status) }
				else { failure = Self.runtimeRouteFailure(for: error) }
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
		if lastQualifiedError != nil {
			let nowMS = runtimeMonotonicNowMS()
			if nowMS < deadlineMS {
				do { try await runtimeSleep(deadlineMS - nowMS) }
				catch {
					recordRuntimeColdLaunchUnqualifiedIfNeeded(
						beganDuringColdLaunch: beganDuringColdLaunch,
						plan: plan,
						cancelled: true
					)
					throw error
				}
			}
			let completedMS = runtimeMonotonicNowMS()
			recordRuntimeColdLaunchFailureIfNeeded(
				beganDuringColdLaunch: beganDuringColdLaunch,
				plan: plan,
				qualifiedFailureDurationMS: completedMS >= startedMS ? completedMS - startedMS : 0
			)
		}
		for endpoint in plan.backups {
			guard let base = URL(string: endpoint),
			      let url = Self.resolvedURL(base: base, path: relativePath) else { continue }
			do {
				let result = try await fetchRuntimeTenantBinaryOnce(
					url: url,
					timeoutInterval: Self.timeoutInterval(for: relativePath, method: "GET"),
					cachePolicy: cachePolicy
				)
				guard (200..<300).contains(result.statusCode) else {
					throw IMRuntimeTenantBinaryFetchError.httpStatus(result.statusCode)
				}
				return result
			} catch {
				let failure: IMRuntimeRouteFailure
				if case let IMRuntimeTenantBinaryFetchError.httpStatus(status) = error { failure = .http(status) }
				else { failure = Self.runtimeRouteFailure(for: error) }
				guard failure.decision == .qualifiedNetwork else { throw error }
				lastQualifiedError = error
			}
		}
		throw lastQualifiedError ?? IMRuntimeTenantBinaryFetchError.routeUnavailable
	}

	func runtimeTenantRelativeBinaryPath(_ parsed: URL) -> String? {
		// Absolute URLs are server-owned object identities (including same-origin
		// presigned/OSS URLs) and must never be rewritten onto another route.
		guard parsed.scheme == nil, parsed.host == nil else { return nil }
		let path = parsed.path.isEmpty ? "/" : parsed.path
		guard path.hasPrefix("/api/tenant/") else { return nil }
		return parsed.query.map { "\(path)?\($0)" } ?? path
	}

	func fetchRuntimeTenantBinaryOnce(
		url: URL,
		timeoutInterval: TimeInterval,
		cachePolicy: URLRequest.CachePolicy
	) async throws -> IMRuntimeTenantBinaryFetchResult {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.cachePolicy = cachePolicy
		request.timeoutInterval = max(0.001, timeoutInterval)
		request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
		let result = try await httpTransport.data(for: request)
		guard result.isHTTPResponse, let status = result.statusCode else {
			throw IMRuntimeTenantBinaryFetchError.invalidResponse
		}
		return .init(data: result.data, statusCode: status, resolvedURL: url)
	}

	func schedulePreferredTenantBinaryProbe(
		base: URL,
		path: String,
		cachePolicy: URLRequest.CachePolicy,
		plan: (snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, primary: [String], backups: [String], recovery: Bool)
	) {
		guard preferredHTTPProbeInFlightServices.insert(plan.service).inserted else { return }
		let tenantGeneration = tenantRouteTransientGeneration
		Task { @MainActor [weak self] in
			guard let self else { return }
			defer {
				if self.runtimeProbeAuthorityIsCurrent(plan.snapshot, tenantGeneration: tenantGeneration) {
					self.preferredHTTPProbeInFlightServices.remove(plan.service)
				}
			}
			do {
				try await self.runtimeSleep(plan.snapshot.policy.preferredProbeStableMS)
				for ordinal in 0..<plan.snapshot.policy.preferredProbeSuccesses {
					if ordinal > 0 { try await self.runtimeSleep(plan.snapshot.policy.preferredProbeIntervalMS) }
					guard self.runtimeProbeAuthorityIsCurrent(
						plan.snapshot, tenantGeneration: tenantGeneration
					) else { return }
					guard let url = Self.resolvedURL(base: base, path: path) else { return }
					let result = try await self.fetchRuntimeTenantBinaryOnce(
						url: url,
						timeoutInterval: TimeInterval(plan.snapshot.policy.preferredFailureBudgetMS) / 1_000,
						cachePolicy: cachePolicy
					)
					let succeeded = (200..<300).contains(result.statusCode)
					self.runtimeRouteSelector.recordPreferredProbe(
						snapshot: plan.snapshot, service: plan.service, kind: .http,
						succeeded: succeeded,
						stableMS: succeeded ? plan.snapshot.policy.preferredProbeStableMS : 0,
						nowMS: self.runtimeMonotonicNowMS()
					)
					guard succeeded,
					      self.runtimeRouteSelector.recovery(plan.snapshot, service: plan.service).recovery else { return }
				}
			} catch {
				guard self.runtimeProbeAuthorityIsCurrent(
					plan.snapshot, tenantGeneration: tenantGeneration
				) else { return }
				self.runtimeRouteSelector.recordPreferredProbe(
					snapshot: plan.snapshot, service: plan.service, kind: .http,
					succeeded: false, stableMS: 0, nowMS: self.runtimeMonotonicNowMS()
				)
			}
		}
	}

#if DEBUG
	@discardableResult
	func activateRuntimeRoutesForTesting(_ snapshot: IMRuntimeRouteSnapshot) -> IMRuntimeRouteApplyResult {
		guard let clean = snapshot.validated(appID: snapshot.appID, tenantID: snapshot.tenantID) else { return .identity }
		let result = runtimeRouteStore.apply(clean, appID: clean.appID, tenantID: clean.tenantID)
		guard result == .applied || result == .idempotent else { return result }
		if clean.tenantID == nil {
			appRouteSnapshot = clean
		} else {
			installValidatedTenantRouteSnapshot(clean)
		}
		return result
	}
#endif

    func platformEntry(entryTicket: String, tenantBaseURL: URL, appID: String, deviceID: String) async throws -> RemoteTenantPlatformEntryResult {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        let body: [String: Any] = [
            "entry_ticket": entryTicket,
            "app_id": normalizedAppID,
            "client_type": "ios"
        ]
#if DEBUG
        recordWorkspaceEntryDiagnosticSummary(
            "platform_entry_request path=/api/tenant/auth/platform-entry app_id=\(normalizedAppID) device_sent=false device=\(Self.debugDiagnosticFingerprint(deviceID)) ticket_present=\(!entryTicket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ticket_length=\(entryTicket.count) ticket=\(Self.debugDiagnosticFingerprint(entryTicket)) tenant_host=\(tenantBaseURL.host ?? "unknown")"
        )
#endif
        // The ticket is single-use and the validated /enter response is the
        // authority for this exchange. Do not let persisted recovery reorder
        // the explicit base or replay the POST on another runtime endpoint.
        let result: RemoteTenantPlatformEntryResult = try await requestOnce(
            base: tenantBaseURL,
            path: "/api/tenant/auth/platform-entry",
            method: "POST",
            body: body
        )
        return result
    }

    func switchTenant(tenantID: String, platformToken: String?, appID: String, deviceID: String) async throws -> RemoteTenantSwitchResult {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        let base = try await platformAPIBase(appID: normalizedAppID)
        return try await request(
            base: base,
            path: "/api/platform/tenants/\(tenantID.urlPathEncoded)/switch",
            method: "POST",
            bearer: platformToken,
            body: [
                "app_id": normalizedAppID,
                "device_id": deviceID
            ]
        )
    }

    func listWorkspaces(context: IMAPIContext) async throws -> [RemoteWorkspaceTenant] {
        try requireIM(context)
        let data: RemoteList<RemoteWorkspaceTenant> = try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/workspaces",
            bearer: context.imToken,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return data.items
    }

    func searchWorkspaces(context: IMAPIContext, keyword: String) async throws -> [RemoteWorkspaceTenant] {
        try requireIM(context)
        let encodedKeyword = keyword.urlQueryEncoded
        let queryItems = ["q", "tenant_code", "code", "keyword", "name"]
            .map { "\($0)=\(encodedKeyword)" }
            .joined(separator: "&")
        let data: RemoteList<RemoteWorkspaceTenant> = try await request(base: tenantBase(for: context), path: "/api/tenant/workspaces/search?\(queryItems)", bearer: context.imToken)
        return data.items
    }

    func joinWorkspace(context: IMAPIContext, tenantCode: String, reason: String = "") async throws -> RemoteWorkspaceJoinResult {
        try requireIM(context)
        var body: [String: Any] = ["source": "ios_workspace_search"]
        let normalizedTenantCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
        if !normalizedTenantCode.isEmpty {
            body["tenant_code"] = normalizedTenantCode
        }
        if !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["reason"] = reason
        }
        return try await request(base: tenantBase(for: context), path: "/api/tenant/workspaces/join", method: "POST", bearer: context.imToken, body: body)
    }

    func switchWorkspace(context: IMAPIContext, tenantID: String, appID: String, deviceID: String) async throws -> RemoteWorkspaceSwitchResult {
        try requireIM(context)
        return try await request(base: tenantBase(for: context), path: "/api/tenant/workspaces/\(tenantID.urlPathEncoded)/switch", method: "POST", bearer: context.imToken, body: ["app_id": appID, "device_id": deviceID])
    }

    func confirmWorkspaceEntry(context: IMAPIContext, tenantID: String) async throws -> RemoteDefaultWorkspaceResult {
        try requireIM(context)
        let normalizedTenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTenantID.isEmpty else {
            throw IMAPIError.missingContext("tenant_id")
        }
        return try await request(
            base: tenantBase(for: context),
            path: "/api/tenant/workspaces/\(normalizedTenantID.urlPathEncoded)/entry/confirm",
            method: "POST",
            bearer: context.imToken,
            body: [String: String]()
        )
    }

    func setDefaultWorkspace(platformToken: String?, tenantID: String) async throws -> RemoteDefaultWorkspaceResult {
        guard let platformToken, !platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("platform token")
        }
        let base = try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID)
        return try await request(base: base, path: "/api/platform/me/tenants/default", method: "PUT", bearer: platformToken, body: ["tenant_id": tenantID])
    }

    func clearDefaultWorkspace(platformToken: String?) async throws -> RemoteDefaultWorkspaceResult {
        guard let platformToken, !platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("platform token")
        }
        let base = try await platformAPIBase(appID: IMAPIContext.canonicalIOSAppID)
        return try await request(base: base, path: "/api/platform/me/tenants/default", method: "DELETE", bearer: platformToken)
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

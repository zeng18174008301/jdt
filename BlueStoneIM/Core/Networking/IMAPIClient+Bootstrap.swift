import Foundation

@MainActor
extension IMAPIClient {
    func accessDiscoveryEndpoints(context: IMAPIContext) async throws -> RemoteAccessDiscoveryResponse {
        try await accessDiscoveryEndpoints(context: context, endpointURL: nil, timeoutInterval: 2.5)
    }

    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse {
        let requestPath: String
        if let endpointURL {
            guard let components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  let host = components.host,
                  RealtimeEndpointAddressValidator.isDomainName(host) else {
                throw AccessDiscoveryTrustError.endpointInvalid
            }
            requestPath = endpointURL.absoluteString
        } else {
            requestPath = "/api/tenant/access/v1/endpoints"
        }
        var body: [String: Any] = [
            "contract_version": 2,
            "app_id": IMAPIContext.normalizedIOSAppID(context.appID),
            "platform": "ios",
            "network": "unknown"
        ]
        if let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tenantID.isEmpty {
            body["tenant_id"] = tenantID
        }
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["app_version"] = appVersion
        }
        let trust = AccessDiscoveryTrustConfiguration.load()
        let response: RemoteAccessDiscoveryResponse
        if trust.required {
            let envelope: SignedAccessDiscoveryEnvelope = try await request(
                base: tenantBase(for: context),
                path: requestPath,
                method: "POST",
                bearer: context.imToken,
                body: body,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: min(max(timeoutInterval, 0.001), 2.5)
            )
            response = try trust.verify(envelope, context: context)
        } else {
            response = try await request(
                base: tenantBase(for: context),
                path: requestPath,
                method: "POST",
                bearer: context.imToken,
                body: body,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: min(max(timeoutInterval, 0.001), 2.5)
            )
        }
        AccessDiagnostics.shared.record(
            .discoveryResponse(
                response,
                tenantAPIHost: tenantBase(for: context).host ?? tenantBase(for: context).absoluteString
            )
        )
        return response
    }

    func debugEndpointSummary(context: IMAPIContext) -> String {
        let wsURL = webSocketURL(context: context)
            .map { Self.redactedURLString($0, redactAllQueryValues: true) }
            ?? "unavailable"
        return "platformBase=\(Self.redactedURLString(platformBase, redactAllQueryValues: true)) tenantBase=\(Self.redactedURLString(tenantBase(for: context), redactAllQueryValues: true)) imBase=\(Self.redactedURLString(imBase(for: context), redactAllQueryValues: true)) wsBase=\(wsURL)"
    }

    func appBootstrap(appID: String, forceRefresh: Bool = false) async throws -> RemoteAppBootstrap {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
		if !forceRefresh, bootstrapResolutionCompleted,
           let bootstrapMemory,
           bootstrapMemory.normalizedAppID == normalizedAppID,
           let bootstrapMemoryExpiresAt,
           bootstrapMemoryExpiresAt > Date() {
            return bootstrapMemory
        }
		guard let hosts = bootstrapHostConfiguration else {
			throw bootstrapConfigurationBlocked
				? IMAPIError.businessForbidden(code: "bootstrap_host_configuration_invalid", message: "应用启动域名配置无效", error: nil)
				: IMAPIError.missingContext("bootstrap_host")
		}
		try Task.checkCancellation()
		let totalAttemptStartedMS = runtimeMonotonicNowMS()
		let totalBudgetMS = IMAppBootstrapFailoverPolicy.totalFailureBudgetMS(
			originCount: hosts.orderedBases.count
		)
		let totalDeadlineMS = IMAppBootstrapFailoverPolicy.deadlineMS(
			startedAtMS: totalAttemptStartedMS,
			budgetMS: totalBudgetMS
		)
		var lastQualifiedError: Error?
		for base in hosts.orderedBases {
			try Task.checkCancellation()
			let originStartedMS = runtimeMonotonicNowMS()
			guard originStartedMS < totalDeadlineMS else { break }
			let originDeadlineMS = min(
				IMAppBootstrapFailoverPolicy.deadlineMS(
					startedAtMS: originStartedMS,
					budgetMS: IMAppBootstrapFailoverPolicy.perOriginFailureBudgetMS
				),
				totalDeadlineMS
			)
			do {
				let bootstrap = try await requestAppBootstrap(
					from: base,
					appID: normalizedAppID,
					cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
					deadlineMS: originDeadlineMS
				)
				try acceptAppBootstrap(
					bootstrap,
					appID: normalizedAppID,
					selectedBase: base,
					hostConfiguration: hosts,
					restoredFromCache: false,
					persistLastGood: true
				)
				bootstrapResolutionCompleted = true
				return bootstrap
			} catch {
				try Task.checkCancellation()
				guard Self.appBootstrapFailureDecision(for: error) == .qualifiedNetwork else { throw error }
				lastQualifiedError = error
			}
		}

		let environment = Self.configuredAppBootstrapEnvironment()
		let snapshots = IMAppBootstrapLastGoodStore.snapshots(
			appID: normalizedAppID,
			environment: environment,
			servingHosts: hosts.orderedBases.compactMap(\.host)
		)
		let allSnapshots = IMAppBootstrapLastGoodStore.snapshots(
			appID: normalizedAppID,
			environment: environment,
			servingHosts: hosts.orderedBases.compactMap(\.host),
			allowExpired: true
		)
		if let cached = Self.highestConsistentCachedBootstrap(
			snapshots,
			highWaterSnapshots: allSnapshots,
			appID: normalizedAppID,
			environment: environment,
			packaged: packagedBootstrapHostConfiguration
		),
		   let servingBase = hosts.base(matchingBootstrapHost: cached.servingHost),
		   (try? acceptAppBootstrap(
				cached.bootstrap,
				appID: normalizedAppID,
				selectedBase: servingBase,
				hostConfiguration: hosts,
				restoredFromCache: true,
				persistLastGood: false
		   )) != nil {
			bootstrapResolutionCompleted = true
			print("[JHT DR] app_bootstrap_last_good app_id=\(normalizedAppID)")
			return cached.bootstrap
		}
		throw lastQualifiedError ?? URLError(.timedOut)
    }

	func requestAppBootstrap(
		from base: URL,
		appID: String,
		cachePolicy: URLRequest.CachePolicy,
		deadlineMS: UInt64?
	) async throws -> RemoteAppBootstrap {
		try Task.checkCancellation()
		let timeoutInterval: TimeInterval?
		if let deadlineMS {
			let nowMS = runtimeMonotonicNowMS()
			guard nowMS < deadlineMS else { throw URLError(.timedOut) }
			timeoutInterval = TimeInterval(deadlineMS - nowMS) / 1_000
		} else {
			timeoutInterval = nil
		}
		return try await request(
			base: base,
			path: Self.appBootstrapRequestPath(appID: appID),
			cachePolicy: cachePolicy,
			preserveHTTPStatusErrors: true,
			requiredHTTPStatus: 200,
			timeoutInterval: timeoutInterval,
			propagateTaskCancellation: true,
			expectedResponseOrigin: base
		)
	}

    nonisolated static func appBootstrapRequestPath(appID: String) -> String {
        "/.well-known/wenxintong-app.json?app_id=\(appID.urlQueryEncoded)"
    }

	func acceptAppBootstrap(
		_ bootstrap: RemoteAppBootstrap,
		appID: String,
		selectedBase: URL?,
		hostConfiguration: IMAppBootstrapHostConfiguration,
		restoredFromCache: Bool,
		persistLastGood: Bool
	) throws {
		guard let acceptedBase = selectedBase,
		      hostConfiguration.containsBase(acceptedBase) else {
			throw IMAPIError.businessForbidden(code: "bootstrap_host_mismatch", message: "应用启动域名不匹配", error: nil)
		}
		let isV2 = bootstrap.contractVersion == 2
		if isV2 {
			guard Self.validatedPlatformBootstrapBases(
				bootstrap,
				packaged: packagedBootstrapHostConfiguration
			) != nil else {
				throw IMAPIError.businessForbidden(code: "bootstrap_host_mismatch", message: "应用启动域名不匹配", error: nil)
			}
			let expectedEnvironment = Self.configuredAppBootstrapEnvironment()
			if !expectedEnvironment.isEmpty {
				guard Self.normalizedAppBootstrapEnvironment(bootstrap.environment) == expectedEnvironment else {
					throw IMAPIError.businessForbidden(code: "app_context_mismatch", message: "应用配置不匹配，请联系管理员", error: nil)
				}
			}
			guard bootstrap.appID == appID else {
				throw IMAPIError.businessForbidden(code: "app_context_mismatch", message: "应用配置不匹配，请联系管理员", error: nil)
			}
            if ["disabled", "tombstone"].contains(bootstrap.publicationStatus ?? "") {
                guard let environment = bootstrap.environment,
                      let revision = bootstrap.publicationRevision,
                      let publicationID = bootstrap.publicationID,
                      let fingerprint = bootstrap.profileFingerprint,
                      let keysetRevision = bootstrap.keysetRevision else {
                    throw IMAPIError.businessForbidden(code: "route_contract_mismatch", message: "应用启动配置撤销合同不完整", error: nil)
                }
                let revoked = runtimeRouteStore.applyRevocation(
                    environment: environment,
                    appID: appID,
                    tenantID: nil,
                    revision: revision,
                    publicationID: publicationID,
                    profileFingerprint: fingerprint,
                    status: bootstrap.publicationStatus ?? "",
                    keysetRevision: keysetRevision
                )
                guard revoked == .revoked || revoked == .idempotent else {
                    throw IMAPIError.businessForbidden(code: "route_revision_rejected", message: "应用启动配置撤销版本已拒绝", error: nil)
                }
                IMAppBootstrapLastGoodStore.clear(appID: appID)
                appRouteSnapshot = nil
                throw IMAPIError.businessForbidden(code: "app_disabled", message: "当前应用已停用", error: nil)
            }
			guard bootstrap.hasValidV2ConfigHash else {
				throw IMAPIError.businessForbidden(code: "config_hash_mismatch", message: "应用启动配置校验失败", error: nil)
			}
			guard let clean = bootstrap.runtimeRouteSnapshot.validated(appID: appID, tenantID: nil) else {
				throw IMAPIError.businessForbidden(code: "route_contract_mismatch", message: "应用启动配置合同不匹配", error: nil)
			}
			let result = runtimeRouteStore.apply(clean, appID: appID, tenantID: nil)
			switch result {
			case .applied, .idempotent:
				break
			case .rollback:
				throw IMAPIError.businessForbidden(code: "route_revision_rollback", message: "应用启动配置版本回退", error: nil)
			case .conflict:
				throw IMAPIError.businessForbidden(code: "route_revision_conflict", message: "应用启动配置版本冲突", error: nil)
			default:
				throw IMAPIError.businessForbidden(code: "route_contract_mismatch", message: "应用启动配置不可用", error: nil)
			}
			appRouteSnapshot = clean
		} else if trustedPreloginPlatformBase == nil {
			// Unsigned public bootstrap is accepted only under the strict v2
			// HTTPS + Host/AppId + monotonic revision/hash contract.
			throw IMAPIError.businessForbidden(code: "route_contract_required", message: "应用启动配置合同缺失", error: nil)
		}
		guard let base = Self.platformBaseURL(from: bootstrap) else {
			throw IMAPIError.businessForbidden(code: "route_contract_mismatch", message: "平台服务入口缺失", error: nil)
		}
        if let trustedPreloginPlatformBase {
            guard Self.trustedPlatformBaseAfterUnsignedBootstrap(
                declaredBase: base,
                trustedBase: trustedPreloginPlatformBase
            ) != nil,
			      Self.sameOrigin(acceptedBase, trustedPreloginPlatformBase) else {
				throw IMAPIError.businessForbidden(code: "bootstrap_host_mismatch", message: "可信平台入口不匹配", error: nil)
            }
        }
		bootstrapMemory = bootstrap
		bootstrapMemoryExpiresAt = Date().addingTimeInterval(TimeInterval(max(30, bootstrap.ttlSeconds)))
		if let platformBases = Self.validatedPlatformBootstrapBases(
			bootstrap,
			packaged: packagedBootstrapHostConfiguration
		), let merged = Self.mergedBootstrapHostConfiguration(
			platformBases: platformBases,
			packaged: packagedBootstrapHostConfiguration
		) {
			bootstrapHostConfiguration = merged
		}
		bootstrapPublicBase = acceptedBase
		bootstrapRestoredFromCache = restoredFromCache
		bootstrapPlatformBase = trustedPreloginPlatformBase ?? base
		if isV2 {
			if let snapshot = appRouteSnapshot { restoreRuntimeBases(from: snapshot) }
		}
		if persistLastGood {
			IMAppBootstrapLastGoodStore.save(
				bootstrap,
				appID: appID,
				environment: Self.configuredAppBootstrapEnvironment(),
				servingHost: acceptedBase.host
			)
		}
    }

	nonisolated static func validatedPlatformBootstrapBases(
		_ bootstrap: RemoteAppBootstrap,
		packaged: IMAppBootstrapHostConfiguration?
	) -> [URL]? {
		let isLegacyPayload = bootstrap.domains.isEmpty && !bootstrap.bootstrapHost.isEmpty
		let rawDomains = isLegacyPayload ? [bootstrap.bootstrapHost] : bootstrap.domains
		let bases = rawDomains.compactMap { raw -> URL? in
			let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard !host.isEmpty,
			      host == raw,
			      !host.contains("://"),
			      !host.contains(where: { " /@?#:*".contains($0) }) else { return nil }
			return URL(string: "https://\(host)")
		}
		guard bases.count == rawDomains.count,
		      bases.count <= IMAppBootstrapHostConfiguration.maximumBaseCount else { return nil }
		if bases.isEmpty {
			return bootstrap.bootstrapHost.isEmpty ? [] : nil
		}
		guard let platform = IMAppBootstrapHostConfiguration(orderedBases: bases),
		      platform.primaryHost == bootstrap.bootstrapHost.lowercased() else { return nil }
		if isLegacyPayload, let packaged,
		   !packaged.containsBootstrapHost(platform.primaryHost) { return nil }
		return platform.orderedBases
	}

	nonisolated static func mergedBootstrapHostConfiguration(
		platformBases: [URL],
		packaged: IMAppBootstrapHostConfiguration?
	) -> IMAppBootstrapHostConfiguration? {
		var seen = Set<String>()
		var merged: [URL] = []
		for base in platformBases + (packaged?.orderedBases ?? []) {
			let host = base.host?.lowercased() ?? ""
			guard !host.isEmpty else { continue }
			if seen.insert(host).inserted { merged.append(base) }
		}
		return merged.isEmpty ? nil : IMAppBootstrapHostConfiguration(effectiveOrderedBases: merged)
	}

	nonisolated static func highestConsistentCachedBootstrap(
		_ snapshots: [IMAppBootstrapLastGoodSnapshot],
		highWaterSnapshots: [IMAppBootstrapLastGoodSnapshot]? = nil,
		appID: String,
		environment: String,
		packaged: IMAppBootstrapHostConfiguration?
	) -> IMAppBootstrapLastGoodSnapshot? {
		let valid = snapshots.filter {
			isValidCachedAppBootstrap(
				$0.bootstrap,
				appID: appID,
				environment: environment,
				packaged: packaged
			)
		}
		let highWater = (highWaterSnapshots ?? snapshots).filter {
			isValidCachedAppBootstrap(
				$0.bootstrap,
				appID: appID,
				environment: environment,
				packaged: packaged
			)
		}
		guard let revision = highWater.map({ $0.bootstrap.routeRevision }).max() else { return nil }
		let highWaterAtRevision = highWater.filter { $0.bootstrap.routeRevision == revision }
		let hashes = Set(highWaterAtRevision.map { $0.bootstrap.configHash.lowercased() })
		guard hashes.count == 1 else { return nil }
		let hash = hashes.first!
		return valid
			.filter {
				$0.bootstrap.routeRevision == revision
					&& $0.bootstrap.configHash.lowercased() == hash
			}
			.max { $0.savedAt < $1.savedAt }
	}

	nonisolated static func isValidCachedAppBootstrap(
		_ bootstrap: RemoteAppBootstrap,
		appID: String,
		environment: String,
		packaged: IMAppBootstrapHostConfiguration?
	) -> Bool {
		let expectedEnvironment = normalizedAppBootstrapEnvironment(environment)
		let actualEnvironment = normalizedAppBootstrapEnvironment(bootstrap.environment)
		guard bootstrap.contractVersion == 2,
		      actualEnvironment == expectedEnvironment,
		      bootstrap.appID == appID,
		      !["disabled", "tombstone"].contains(bootstrap.publicationStatus ?? ""),
		      validatedPlatformBootstrapBases(bootstrap, packaged: packaged) != nil,
		      bootstrap.hasValidV2ConfigHash,
		      bootstrap.runtimeRouteSnapshot.validated(appID: appID, tenantID: nil) != nil,
		      platformBaseURL(from: bootstrap) != nil else { return false }
		return true
	}

    nonisolated static func platformBaseURL(
		from bootstrap: RemoteAppBootstrap,
		selector: IMRuntimeRouteSelector? = nil,
		snapshot: IMRuntimeRouteSnapshot? = nil
	) -> URL? {
		let declared = snapshot.flatMap { selector?.endpoints($0, service: .platformAPI).first }
			?? bootstrap.routes[IMRuntimeRouteService.platformAPI.rawValue]?.preferred.first
			?? bootstrap.directory.apiBaseURL
		guard var components = URLComponents(string: declared.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        if components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "api" {
            components.path = ""
        }
        guard let normalizedRaw = components.url?.absoluteString else { return nil }
        return normalizedHTTPBaseURL(normalizedRaw, allowLocalOrInsecure: allowsRuntimeAPIBaseOverride)
    }

    nonisolated static func trustedPlatformBaseAfterUnsignedBootstrap(
        declaredBase: URL,
        trustedBase: URL
    ) -> URL? {
        guard declaredBase.scheme?.lowercased() == "https",
              trustedBase.scheme?.lowercased() == "https",
              declaredBase.host?.lowercased() == trustedBase.host?.lowercased(),
              effectiveHTTPSPort(declaredBase) == effectiveHTTPSPort(trustedBase) else {
            return nil
        }
        return trustedBase
    }

    nonisolated static func effectiveHTTPSPort(_ url: URL) -> Int {
        url.port ?? 443
    }

    func platformAPIBase(appID: String, forceRefresh: Bool = false) async throws -> URL {
        guard resolvesPlatformBaseViaBootstrap else { return platformBase }
		if !forceRefresh, bootstrapResolutionCompleted, let snapshot = appRouteSnapshot,
		   snapshot.appID == IMAPIContext.normalizedIOSAppID(appID),
		   let raw = runtimeRouteSelector.endpoints(snapshot, service: .platformAPI).first,
		   let restoredBase = Self.normalizedHTTPBaseURL(raw, allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride) {
			return restoredBase
        }
		_ = try await appBootstrap(appID: appID, forceRefresh: forceRefresh)
		guard let snapshot = appRouteSnapshot,
		      let raw = runtimeRouteSelector.endpoints(snapshot, service: .platformAPI).first,
		      let routedBase = Self.normalizedHTTPBaseURL(raw, allowLocalOrInsecure: Self.allowsRuntimeAPIBaseOverride) else {
			throw IMAPIError.missingContext("platform_api_route")
		}
		return routedBase
	}

	nonisolated static func appBootstrapFailureDecision(for error: Error) -> IMRuntimeRouteFailureDecision {
		if error is DecodingError {
			return .qualifiedNetwork
		}
		if let urlError = error as? URLError {
			return urlError.code == .cancelled ? .noFailover : .qualifiedNetwork
		}
		if let apiError = error as? IMAPIError {
			switch apiError {
			case .missingContext, .forcedAuthRequired:
				return .noFailover
			default:
				// A Bootstrap response is authoritative only for one exact
				// Host + AppId request. Every HTTP/business/contract failure is
				// therefore candidate-local and advances to the next pinned Host.
				return .qualifiedNetwork
			}
		}
		return IMAppBootstrapFailoverPolicy.decision(for: runtimeRouteFailure(for: error))
	}

	nonisolated static func runtimeRouteFailure(for error: Error) -> IMRuntimeRouteFailure {
		if let realtimeError = error as? RealtimeClientError {
			switch realtimeError {
			case .acknowledgementTimeout: return .websocketHeartbeat
			case .generationDeadlineExceeded: return .timeout
			case .connectFrameEncodingFailed: return .business
			}
		}
		if let urlError = error as? URLError {
			switch urlError.code {
			case .cannotFindHost, .dnsLookupFailed: return .dns
			case .cannotConnectToHost, .networkConnectionLost: return .connect
			case .timedOut: return .timeout
			case .internationalRoamingOff, .dataNotAllowed, .notConnectedToInternet: return .offline
			case .cancelled: return .cancelled
			case .serverCertificateHasBadDate, .serverCertificateUntrusted,
			     .serverCertificateHasUnknownRoot, .secureConnectionFailed,
			     .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
				return .tlsCertificate
			default:
				return .business
			}
		}
		if let apiError = error as? IMAPIError {
			switch apiError {
			case .httpStatus(let status, _): return .http(status)
			case .businessForbidden(let code, _, _):
				switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
				case "app_context_mismatch", "app_domain_app_mismatch": return .appIDMismatch
				case "tenant_context_mismatch", "route_tenant_mismatch": return .tenantMismatch
				case "bootstrap_host_mismatch", "route_host_mismatch": return .hostMismatch
				case "route_hash_mismatch", "config_hash_mismatch": return .configHashMismatch
				case "route_revision_rejected", "route_revision_conflict", "route_revision_rollback": return .revisionRejected
				case "route_contract_mismatch", "route_contract_required": return .contractMismatch
				default: return .business
				}
			case .badURL: return .hostMismatch
			case .emptyResponse: return .business
			default: return .business
			}
		}
		let nsError = error as NSError
		if nsError.domain == NSPOSIXErrorDomain, [ECONNRESET, ECONNREFUSED, EPIPE].contains(Int32(nsError.code)) {
			return .reset
		}
		return .business
	}

    func currentAppPolicy(appID: String, forceRefresh: Bool = false) async throws -> RemoteAppCurrentPolicy {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = try await platformAPIBase(appID: normalizedAppID, forceRefresh: forceRefresh)
        var path = "/api/platform/apps/current-policy?app_id=\(normalizedAppID.urlQueryEncoded)"
        if forceRefresh {
            let cacheBust = Int(Date().timeIntervalSince1970 * 1000)
            path += "&_ts=\(cacheBust)"
        }
        let policy: RemoteAppCurrentPolicy = try await request(
            base: base,
            path: path,
            cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        )
        return bootstrapMemory.map { policy.settingStartupPolicyHints(from: $0) } ?? policy
    }

    func resolveEnterpriseContext(tenantCode: String, appID: String, deviceID: String) async throws -> RemoteEnterpriseContextResult {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        let normalizedCode = try Self.normalizedOptionalRegistrationEntryCode(tenantCode)
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty, !normalizedDeviceID.isEmpty else {
            throw IMAPIError.businessForbidden(code: "entry_code_invalid", message: "企业码无效或暂不可用", error: nil)
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        return try await request(
            base: base,
            path: "/api/platform/auth/enterprise-context/resolve",
            method: "POST",
            body: [
                "app_id": normalizedAppID,
                "device_id": normalizedDeviceID,
                "tenant_code": normalizedCode
            ]
        )
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：用户协议/隐私协议固定到实际 API Origin
    private struct LegalDocManifestAuthority {
        let manifest: RemoteLegalDocManifest
        let base: URL
        let bodyPaths: [String]
    }

    func publicLegalDocs(appID: String) async throws -> RemoteLegalDocManifest {
        Self.fixedLegalDocumentManifest(appID: appID)
    }

    func legalDocumentContent(type: LegalDocumentType, appID: String, context: IMAPIContext?) async throws -> LegalDocumentContent {
        return try await fixedLegalDocumentContent(type: type, appID: appID)
    }

    private func fixedLegalDocumentContent(type: LegalDocumentType, appID: String) async throws -> LegalDocumentContent {
        let documentURL = type.fixedWebURL
        let baseURL = try Self.legalDocumentFixedBaseURL(for: documentURL)
        let html = try await legalDocumentHTML(from: documentURL, expectedOrigin: baseURL)
        return LegalDocumentContent(
            type: type,
            title: type.title,
            html: html,
            sourceURL: documentURL,
            baseURL: baseURL,
            manifest: Self.fixedLegalDocumentManifest(appID: appID)
        )
    }

    private nonisolated static func fixedLegalDocumentManifest(appID: String) -> RemoteLegalDocManifest {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        return RemoteLegalDocManifest(
            appID: normalizedAppID,
            manifestRevision: 0,
            manifestHash: "fixed-wdatong-legal-docs",
            docs: LegalDocumentType.allCases.map { type in
                RemoteLegalDoc(
                    docType: type.rawValue,
                    title: type.title,
                    downloadURL: type.fixedWebURL.absoluteString
                )
            }
        )
    }

    private nonisolated static func legalDocumentFixedBaseURL(for url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw IMAPIError.badURL("legal_doc_fixed_url_invalid")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else {
            throw IMAPIError.badURL("legal_doc_fixed_url_invalid")
        }
        return baseURL
    }

    private func remoteLegalDocumentContent(type: LegalDocumentType, appID: String, context: IMAPIContext?) async throws -> LegalDocumentContent {
        let authority = try await legalDocsManifestAuthority(appID: appID, context: context)
        guard let document = authority.manifest.document(type: type) else {
            throw IMAPIError.businessForbidden(
                code: "legal_doc_manifest_not_found",
                message: "\(type.title)暂未配置",
                error: nil
            )
        }
        let documentURL = try Self.resolvedLegalDocBodyURL(
            document.downloadURL,
            base: authority.base,
            expectedPaths: authority.bodyPaths
        )
        let html = try await legalDocumentHTML(from: documentURL, expectedOrigin: authority.base)
        return LegalDocumentContent(
            type: type,
            title: document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? type.title : document.title,
            html: html,
            sourceURL: documentURL,
            baseURL: authority.base,
            manifest: authority.manifest
        )
    }

    func resolveLegalDocAssetURL(_ rawValue: String, appID: String) async throws -> String {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        return try Self.resolvedLegalDocAssetURL(rawValue, base: base).absoluteString
    }

    private func legalDocsManifestAuthority(appID: String, context: IMAPIContext?) async throws -> LegalDocManifestAuthority {
        let tenantID = context?.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let context, !tenantID.isEmpty {
            return try await tenantLegalDocsManifestAuthority(appID: appID, context: context)
        }
        if let knownTenantAuthority = try await knownTenantLegalDocsManifestAuthority(appID: appID) {
            return knownTenantAuthority
        }
        return try await platformLegalDocsManifestAuthority(appID: appID)
    }

    private func platformLegalDocsManifestAuthority(appID: String) async throws -> LegalDocManifestAuthority {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = try await platformAPIBase(appID: normalizedAppID)
        do {
            return try await platformLegalDocsManifestAuthority(
                appID: normalizedAppID,
                base: base,
                manifestPath: Self.platformLegalDocsManifestPath(appID: normalizedAppID),
                bodyPaths: [Self.platformLegalDocsManifestEndpointPath]
            )
        } catch {
            if error is CancellationError {
                throw error
            }
            try Task.checkCancellation()
            if let fallback = try await bootstrapLegalDocsManifestAuthority(
                appID: normalizedAppID,
                base: base
            ) {
                return fallback
            }
            throw error
        }
    }

    private func platformLegalDocsManifestAuthority(
        appID: String,
        base: URL,
        manifestPath: String,
        bodyPaths: [String]
    ) async throws -> LegalDocManifestAuthority {
        let manifest: RemoteLegalDocManifest = try await request(
            base: base,
            path: manifestPath,
            cachePolicy: .reloadIgnoringLocalCacheData,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: base
        )
        try validateLegalDocManifest(manifest, appID: appID)
        return LegalDocManifestAuthority(
            manifest: manifest,
            base: base,
            bodyPaths: Self.uniqueLegalDocBodyPaths(bodyPaths)
        )
    }

    private func bootstrapLegalDocsManifestAuthority(
        appID: String,
        base: URL
    ) async throws -> LegalDocManifestAuthority? {
        guard let legal = bootstrapMemory?.legal,
              Self.hasBootstrapLegalDocsManifestCandidate(legal) else {
            return nil
        }
        let manifestPath = Self.legalDocsManifestPath(from: legal, appID: appID)
        guard let requestPath = Self.legalDocsManifestRequestPath(manifestPath, base: base),
              requestPath != Self.platformLegalDocsManifestPath(appID: appID) else {
            return nil
        }
        let bodyPaths = Self.uniqueLegalDocBodyPaths([
            Self.platformLegalDocsManifestEndpointPath,
            Self.legalDocsManifestEndpointPath(from: requestPath)
        ].compactMap { $0 })
        return try await platformLegalDocsManifestAuthority(
            appID: appID,
            base: base,
            manifestPath: requestPath,
            bodyPaths: bodyPaths
        )
    }

    private func tenantLegalDocsManifestAuthority(appID: String, context: IMAPIContext) async throws -> LegalDocManifestAuthority {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let base = tenantBase(for: context)
        return try await tenantLegalDocsManifestAuthority(appID: normalizedAppID, base: base)
    }

    private func knownTenantLegalDocsManifestAuthority(appID: String) async throws -> LegalDocManifestAuthority? {
        guard let base = knownTenantLegalDocsBase() else { return nil }
        do {
            return try await tenantLegalDocsManifestAuthority(appID: appID, base: base)
        } catch {
            if error is CancellationError {
                throw error
            }
            try Task.checkCancellation()
            return nil
        }
    }

    private func knownTenantLegalDocsBase() -> URL? {
        if let snapshot = tenantRouteSnapshot,
           let raw = runtimeRouteSelector.endpoints(snapshot, service: .tenantAPI).first,
           let routed = Self.normalizedTenantAPIBaseURL(raw) {
            return routed
        }
        guard !Self.isReleasePlaceholderTenantBase(tenantBase) else {
            return nil
        }
        return tenantBase
    }

    private func tenantLegalDocsManifestAuthority(appID: String, base: URL) async throws -> LegalDocManifestAuthority {
        let normalizedAppID = IMAPIContext.normalizedIOSAppID(appID)
        guard !normalizedAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPIError.missingContext("app_id")
        }
        let manifest: RemoteLegalDocManifest = try await request(
            base: base,
            path: Self.tenantLegalDocsManifestPath(appID: normalizedAppID),
            cachePolicy: .reloadIgnoringLocalCacheData,
            propagateTaskCancellation: true,
            runtimeRouteReplayPolicy: .currentEndpointOnly,
            expectedResponseOrigin: base
        )
        try validateLegalDocManifest(manifest, appID: normalizedAppID)
        return LegalDocManifestAuthority(
            manifest: manifest,
            base: base,
            bodyPaths: [Self.tenantLegalDocsManifestEndpointPath]
        )
    }

    private func validateLegalDocManifest(_ manifest: RemoteLegalDocManifest, appID: String) throws {
        guard Self.matchesFixedAppID(manifest.appID, expected: appID) else {
            throw IMAPIError.businessForbidden(
                code: "app_context_mismatch",
                message: "应用协议配置不匹配，请联系管理员",
                error: nil
            )
        }
    }

    private func legalDocumentHTML(from url: URL, expectedOrigin: URL) async throws -> String {
        guard Self.isAllowedLegalDocAssetURL(url, base: expectedOrigin) else {
            throw IMAPIError.badURL("legal_doc_cross_origin_not_allowed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeoutInterval(for: url.path, method: "GET")
        request.setValue("JianHuiTong-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let result = try await rawHTTPResult(
            for: request,
            dedupeKey: nil,
            propagateTaskCancellation: true,
            expectedResponseOrigin: expectedOrigin
        )
        guard result.isHTTPResponse, let statusCode = result.statusCode else {
            throw IMAPIError.emptyResponse
        }
        guard statusCode == 200 else {
            throw IMAPIError.httpStatus(
                statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
            )
        }
        guard let responseURL = result.responseURL,
              Self.isAllowedLegalDocAssetURL(responseURL, base: expectedOrigin) else {
            throw IMAPIError.badURL("legal_doc_cross_origin_not_allowed")
        }
        guard !result.data.isEmpty else {
            throw IMAPIError.emptyResponse
        }
        return String(data: result.data, encoding: .utf8) ?? String(decoding: result.data, as: UTF8.self)
    }
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

    func appPublicBase(appID: String) async throws -> URL {
        if let bootstrapPublicBase {
            return bootstrapPublicBase
        }
        _ = try await appBootstrap(appID: appID)
		guard let base = bootstrapPublicBase ?? bootstrapHostConfiguration?.primary else {
            throw IMAPIError.missingContext("app_public_base_url")
        }
        return base
    }

    nonisolated static func legalDocsManifestPath(
        from legal: RemoteAppBootstrap.Legal,
        appID rawAppID: String
    ) -> String {
        let appID = IMAPIContext.normalizedIOSAppID(rawAppID)
        let candidate = [legal.legalDocsURL, legal.manifestURL]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let fallback = "/.well-known/legal-docs.json"
        var components: URLComponents
        components = legalDocsManifestComponents(from: candidate) ?? URLComponents(string: fallback) ?? URLComponents()
        components.fragment = nil
        var queryItems = (components.queryItems ?? []).filter {
            let name = $0.name.lowercased().replacingOccurrences(of: "-", with: "_")
            return name != "app_id" && name != "appid"
        }
        queryItems.append(URLQueryItem(name: "app_id", value: appID))
        components.queryItems = queryItems
        return components.string ?? "\(fallback)?app_id=\(appID.urlQueryEncoded)"
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：新合同固定 manifest 入口，不使用 bootstrap legal 自证路径
    nonisolated static func platformLegalDocsManifestPath(appID rawAppID: String) -> String {
        "\(platformLegalDocsManifestEndpointPath)?app_id=\(IMAPIContext.normalizedIOSAppID(rawAppID).urlQueryEncoded)"
    }

    nonisolated static func tenantLegalDocsManifestPath(appID rawAppID: String) -> String {
        "\(tenantLegalDocsManifestEndpointPath)?app_id=\(IMAPIContext.normalizedIOSAppID(rawAppID).urlQueryEncoded)"
    }

    nonisolated static var platformLegalDocsManifestEndpointPath: String {
        "/api/app/legal-docs"
    }

    nonisolated static var tenantLegalDocsManifestEndpointPath: String {
        "/api/tenant/public/legal-docs"
    }

    nonisolated static func resolvedLegalDocAssetURL(_ rawValue: String, base: URL) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              isAllowedLegalDocAssetURL(resolved, base: base) else {
            throw IMAPIError.badURL("legal_doc_cross_origin_not_allowed")
        }
        return resolved
    }

    nonisolated static func resolvedLegalDocBodyURL(_ rawValue: String, base: URL, expectedPath: String) throws -> URL {
        try resolvedLegalDocBodyURL(rawValue, base: base, expectedPaths: [expectedPath])
    }

    nonisolated static func resolvedLegalDocBodyURL(_ rawValue: String, base: URL, expectedPaths: [String]) throws -> URL {
        let resolved = try resolvedLegalDocAssetURL(rawValue, base: base)
        let normalizedExpectedPaths = Set(uniqueLegalDocBodyPaths(expectedPaths))
        guard normalizedExpectedPaths.contains(resolved.path) else {
            throw IMAPIError.badURL("legal_doc_cross_origin_not_allowed")
        }
        return resolved
    }
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

    nonisolated static func hasBootstrapLegalDocsManifestCandidate(_ legal: RemoteAppBootstrap.Legal) -> Bool {
        !legal.legalDocsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !legal.manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func legalDocsManifestRequestPath(_ rawValue: String, base: URL) -> String? {
        guard let resolved = try? resolvedLegalDocAssetURL(rawValue, base: base),
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }

    nonisolated static func legalDocsManifestEndpointPath(from rawValue: String) -> String? {
        guard let components = URLComponents(string: rawValue) else { return nil }
        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? path : "/\(path)"
    }

    nonisolated static func uniqueLegalDocBodyPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { rawPath in
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
            guard seen.insert(normalizedPath).inserted else { return nil }
            return normalizedPath
        }
    }

    nonisolated static func legalDocsManifestComponents(from rawValue: String?) -> URLComponents? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.user == nil,
              components.password == nil else {
            return nil
        }
        if let scheme = components.scheme?.lowercased() {
            guard ["https", "http"].contains(scheme),
                  components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            return components
        }
        guard components.host == nil else { return nil }
        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if !path.hasPrefix("/") {
            components.path = "/" + path
        }
        return components
    }

    // JHT_MOD_BEGIN LEGAL_API_ORIGIN_20260914 - 修改开始：移除任意 http/https 协议正文兜底，只允许实际 API 同源
    nonisolated static func isAllowedLegalDocAssetURL(_ url: URL, base: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return sameOrigin(url, base)
    }
    // JHT_MOD_END LEGAL_API_ORIGIN_20260914 - 修改结束

    nonisolated static func matchesFixedAppID(_ rawValue: String, expected: String) -> Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
			&& effectiveOriginPort(lhs) == effectiveOriginPort(rhs)
    }

	nonisolated static func effectiveOriginPort(_ url: URL) -> Int? {
		if let port = url.port { return port }
		switch url.scheme?.lowercased() {
		case "https", "wss": return 443
		case "http", "ws": return 80
		default: return nil
		}
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

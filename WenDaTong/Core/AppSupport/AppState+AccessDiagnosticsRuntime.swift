import Foundation

extension AppState {
    func disableAccessDiagnosticsOverlay() {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        AccessDiagnostics.shared.disablePreservingAllowedPolicy()
    }

    func forceDisableAccessDiagnosticsOverlay() {
        AccessDiagnostics.shared.forceDisable()
    }

    func prepareAccessDiagnosticsOverlayForLaunch() {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let appID = currentAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else {
            forceDisableAccessDiagnosticsOverlay()
            return
        }
        // WDT_IOS1_MOUNTED_POLICY_CACHE_SCOPE_20261112
        if let entry = IMAppPolicyLastGoodStore.usable(appID: appID, defaults: appPolicyLastGoodDefaults) {
            applyAccessDiagnosticsPolicy(entry.policy, source: "last-good")
            return
        }
        forceDisableAccessDiagnosticsOverlay()
        beginAccessDiagnosticsPolicyFetch(appID: appID)
    }

    func beginAccessDiagnosticsPolicyFetch(appID: String) {
        AccessDiagnostics.shared.record(
            .bootstrapFetching(
                appID: appID,
                bootstrapHost: accessDiagnosticsBootstrapHost,
				fallbackHost: accessDiagnosticsBootstrapFallbackHost
            )
        )
    }

    func applyAccessDiagnosticsPolicy(_ policy: RemoteAppCurrentPolicy, source: String) {
        // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        syncAccessDiagnosticsActivationScope()
        // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
        let effectiveAppID = accessDiagnosticsAppID(for: policy)
        AccessDiagnostics.shared.applyPolicy(
            AccessDiagnosticsPolicy(
                appID: effectiveAppID,
                overlayConfiguration: policy.accessDiagnosticsOverlayConfiguration,
                copyEnabled: policy.accessDiagnosticsCopyEnabled
            )
        )
        AccessDiagnostics.shared.record(
            .bootstrapSucceeded(
                appID: effectiveAppID,
                bootstrapHost: accessDiagnosticsBootstrapHost,
				fallbackHost: accessDiagnosticsBootstrapFallbackHost,
                source: source
            )
        )
        (api as? IMAPIClient)?.publishAccessDiagnosticsDomainState()
        if apiContext.hasIMSession {
            recordAccessDiagnosticsMerchantEntered()
        }
    }

    // JHT_MOD_BEGIN ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE
    private var currentAccessDiagnosticsActivationScope: AccessDiagnosticsActivationScope? {
        let appID = currentAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return nil }
        guard isAuthenticated, apiContext.hasIMSession else {
            return AccessDiagnosticsActivationScope(
                appID: appID,
                tenantID: nil,
                authPhase: .loggedOut,
                sessionGeneration: 0
            )
        }
        return AccessDiagnosticsActivationScope(
            appID: appID,
            accountID: apiContext.accountID ?? apiContext.imUID ?? currentUser.id,
            tenantID: apiContext.tenantID,
            authPhase: .authenticated,
            sessionGeneration: apiContext.authSessionFence.sessionGeneration,
            deviceID: apiContext.deviceID,
            sessionEpoch: apiContext.sessionEpoch
        )
    }

    func syncAccessDiagnosticsActivationScope() {
        AccessDiagnostics.shared.updateScope(currentAccessDiagnosticsActivationScope)
    }

    func registerAccessDiagnosticsLogoTap(entry: AccessDiagnosticsActivationEntry) {
        syncAccessDiagnosticsActivationScope()
        guard accessDiagnosticsEntryIsAllowed(entry),
              let scope = currentAccessDiagnosticsActivationScope else {
            AccessDiagnostics.shared.resetLogoTapSequence(entry: entry)
            return
        }
        let transition = AccessDiagnostics.shared.registerLogoTap(entry: entry, scope: scope)
        if transition == .opened {
            replayAccessDiagnosticsCurrentState()
        }
    }

    func resetAccessDiagnosticsLogoTapSequence(entry: AccessDiagnosticsActivationEntry) {
        AccessDiagnostics.shared.resetLogoTapSequence(entry: entry)
    }

    private func accessDiagnosticsEntryIsAllowed(_ entry: AccessDiagnosticsActivationEntry) -> Bool {
        switch entry {
        case .loggedOutLoginLogo:
            return !isAuthenticated
                && [.welcome, .phoneLogin, .accountLogin, .phoneRegister, .accountRegister].contains(authScreen)
        case .loggedInAboutLogo:
            return isAuthenticated && apiContext.hasIMSession
        }
    }

    private func replayAccessDiagnosticsCurrentState() {
        guard AccessDiagnostics.shared.isVisible else { return }
        if let policy = currentAppPolicy {
            applyAccessDiagnosticsPolicy(policy, source: "cache")
        } else {
            beginAccessDiagnosticsPolicyFetch(appID: currentAppID)
            (api as? IMAPIClient)?.publishAccessDiagnosticsDomainState()
            if apiContext.hasIMSession {
                recordAccessDiagnosticsMerchantEntered()
            }
        }
    }
    // JHT_MOD_END ACCESS_DIAGNOSTICS_FIVE_TAP_TOGGLE

    private func accessDiagnosticsAppID(for policy: RemoteAppCurrentPolicy) -> String {
        let reportedAppID = policy.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reportedAppID.isEmpty else { return "" }
        return IMAPIContext.normalizedIOSAppID(reportedAppID, allowCustomAppID: true)
    }

	private var accessDiagnosticsBootstrapHost: String {
		if let client = api as? IMAPIClient,
		   let primary = client.configuredAppBootstrapPrimaryBase {
			return primary.host ?? primary.absoluteString
		}
		return api.platformBase.host ?? api.platformBase.absoluteString
    }

	private var accessDiagnosticsBootstrapFallbackHost: String? {
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		guard let client = api as? IMAPIClient else { return nil }
		let candidates = client.configuredAppBootstrapBases.dropFirst().map { base in
			base.host ?? base.absoluteString
		}
		return candidates.isEmpty ? nil : candidates.joined(separator: "、")
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
	}

    private func accessDiagnosticsTenantAPIHost(for context: IMAPIContext? = nil) -> String {
        if let context,
           let url = IMAPIClient.normalizedTenantAPIBaseURL(context.tenantAPIBaseURL) {
            return url.host ?? url.absoluteString
        }
        if let url = IMAPIClient.normalizedTenantAPIBaseURL(apiContext.tenantAPIBaseURL) {
            return url.host ?? url.absoluteString
        }
        return api.tenantBase.host ?? api.tenantBase.absoluteString
    }

    func recordAccessDiagnosticsMerchantResolving(name: String = "当前商户") {
        AccessDiagnostics.shared.record(
            .merchantResolving(name: name, tenantAPIHost: accessDiagnosticsTenantAPIHost())
        )
    }

    func recordAccessDiagnosticsMerchantEntered() {
        let merchantName = currentEnterprise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        AccessDiagnostics.shared.record(
            .merchantEntered(
                name: merchantName.isEmpty ? "当前商户" : merchantName,
                tenantAPIHost: accessDiagnosticsTenantAPIHost()
            )
        )
    }

    func recordAccessDiagnosticsDiscoveryFetching(context: IMAPIContext) {
        guard context.hasIMSession else { return }
        AccessDiagnostics.shared.record(.discoveryFetching(tenantAPIHost: accessDiagnosticsTenantAPIHost(for: context)))
    }

    func recordAccessDiagnosticsDiscoveryOutcome(_ outcome: AccessDiscoveryRefreshOutcome) {
        AccessDiagnostics.shared.record(.discoveryOutcome(outcome))
    }

    func recordAccessDiagnosticsRealtimeRequest(_ request: RealtimeConnectionRequest?, context: IMAPIContext) {
        guard context.hasIMSession else { return }
        guard let request else {
            AccessDiagnostics.shared.record(.failed(reason: "实时连接地址不可用"))
            return
        }
        AccessDiagnostics.shared.record(
            .connectionComparing(
                fallbackURL: request.url,
                quicHost: request.quicRequest?.host
            )
        )
    }

    func redactedRealtimeURLSummary(_ url: URL?) -> String {
        guard let url else { return "unavailable" }
        return IMAPIClient.redactedURLString(url, redactAllQueryValues: true)
    }

    func usesLocalRealtimeFallback(context: IMAPIContext) -> Bool {
        Self.isLocalRealtimeFallbackURL(api.webSocketURL(context: context))
    }

    static func isLocalRealtimeFallbackURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else { return false }
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") else {
            return false
        }
        return url.path == "/im/ws"
    }

    func recordAccessDiagnosticsRealtimeConnected() {
        let snapshot = AccessDiagnostics.shared.snapshot
        AccessDiagnostics.shared.record(
            .connectionSelected(
                currentHost: snapshot.imCurrentHost,
                protocolName: snapshot.connectionProtocol,
                reason: "主链路可用"
            )
        )
    }

    func recordAccessDiagnosticsRealtimeFallback(context: IMAPIContext, reason: String) {
        let fallbackHost = api.webSocketURL(context: context)?.host ?? api.imBase.host ?? api.imBase.absoluteString
        AccessDiagnostics.shared.record(
            .connectionFallback(
                currentHost: fallbackHost,
                protocolName: "WSS",
                reason: reason
            )
        )
    }

}

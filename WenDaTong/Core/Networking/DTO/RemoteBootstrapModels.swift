import Foundation
import IM4Data

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
typealias RemoteAppBootstrap = IM4Data.RemoteAppBootstrap

extension RemoteAppBootstrap: @retroactive Decodable, @retroactive Encodable {
    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case appIDCamel = "appId"
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case platform
        case status
        case domains
        case bootstrapHost = "bootstrap_host"
        case bootstrapHostCamel = "bootstrapHost"
        case appDomain = "app_domain"
        case appDomainCamel = "appDomain"
        case configVersion = "config_version"
        case configVersionCamel = "configVersion"
        case ttlSeconds = "ttl_seconds"
        case ttlSecondsCamel = "ttlSeconds"
        case directory
        case legal
        case configHash = "config_hash"
        case configHashCamel = "configHash"
		case contractVersion = "contract_version"
		case revision
		case routeRevision = "route_revision"
		case routeSource = "route_source"
		case routeStatus = "route_status"
		case routes
		case preferredEndpoints = "preferred_endpoints"
		case routingPolicy = "routing_policy"
        case environment
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "publication_status"
        case keysetRevision = "keyset_revision"
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
        case debugFeatures = "debug_features"
        case debugFeaturesCamel = "debugFeatures"
        case phoneAuthEnabled = "phone_auth_enabled"
        case phoneAuthEnabledCamel = "phoneAuthEnabled"
        case registrationEnabled = "registration_enabled"
        case registrationEnabledCamel = "registrationEnabled"
        case openRegistration = "open_registration"
        case openRegistrationCamel = "openRegistration"
        case enterpriseCodeFirst = "enterprise_code_first"
        case enterpriseCodeFirstCamel = "enterpriseCodeFirst"
        case preferEnterpriseCode = "prefer_enterprise_code"
        case preferEnterpriseCodeCamel = "preferEnterpriseCode"
        case preferredEnterpriseCode = "preferred_enterprise_code"
        case preferredEnterpriseCodeCamel = "preferredEnterpriseCode"
        case policy
        case appPolicy = "app_policy"
        case appPolicyCamel = "appPolicy"
        case authPolicy = "auth_policy"
        case authPolicyCamel = "authPolicy"
        case registerPolicy = "register_policy"
        case registerPolicyCamel = "registerPolicy"
        case loginPolicy = "login_policy"
        case loginPolicyCamel = "loginPolicy"
        case tenantPool = "tenant_pool"
        case tenantPoolCamel = "tenantPool"
    }

    enum DebugFeaturesCodingKeys: String, CodingKey {
        case accessDiagnosticsOverlayEnabled = "access_diagnostics_overlay_enabled"
        case accessDiagnosticsOverlayEnabledCamel = "accessDiagnosticsOverlayEnabled"
    }

    enum AppAuthPolicyCodingKeys: String, CodingKey {
        case phoneAuthEnabled = "phone_auth_enabled"
        case phoneAuthEnabledCamel = "phoneAuthEnabled"
        case registrationEnabled = "registration_enabled"
        case registrationEnabledCamel = "registrationEnabled"
        case openRegistration = "open_registration"
        case openRegistrationCamel = "openRegistration"
        case registrationOpen = "registration_open"
        case registrationOpenCamel = "registrationOpen"
        case enabled
        case enterpriseCodeFirst = "enterprise_code_first"
        case enterpriseCodeFirstCamel = "enterpriseCodeFirst"
        case preferEnterpriseCode = "prefer_enterprise_code"
        case preferEnterpriseCodeCamel = "preferEnterpriseCode"
    }

    init(
        appID: String,
        displayName: String = "",
        platform: String = "",
        status: String = "",
        domains: [String] = [],
        bootstrapHost: String = "",
        appDomain: String = "",
        configVersion: String = "",
        ttlSeconds: Int = 300,
        directory: Directory = Directory(),
        legal: Legal = Legal(),
        configHash: String = "",
		contractVersion: Int = 0,
		routeRevision: UInt64 = 0,
		routeSource: String = "",
		routeStatus: String = "",
		routes: [String: IMRuntimeRouteEndpointSet] = [:],
		preferredEndpoints: [String: [String]] = [:],
		routingPolicy: IMRuntimeRoutePolicy = .init(),
        environment: String? = nil,
        publicationID: String? = nil,
        publicationRevision: UInt64? = nil,
        profileFingerprint: String? = nil,
        lifetimeMode: IMSessionLifetimeMode? = nil,
        publicationStatus: String? = nil,
        keysetRevision: UInt64? = nil,
        accessDiagnosticsOverlayEnabled: Bool = false,
        phoneAuthEnabled: Bool = true,
        registrationEnabled: Bool = true,
        enterpriseCodeFirst: Bool = false,
        preferredEnterpriseCode: String = ""
    ) {
        let __wire_appID: String
        let __wire_displayName: String
        let __wire_platform: String
        let __wire_status: String
        let __wire_domains: [String]
        let __wire_bootstrapHost: String
        let __wire_appDomain: String
        let __wire_configVersion: String
        let __wire_ttlSeconds: Int
        let __wire_directory: Directory
        let __wire_legal: Legal
        let __wire_configHash: String
        let __wire_contractVersion: Int
        let __wire_routeRevision: UInt64
        let __wire_routeSource: String
        let __wire_routeStatus: String
        let __wire_routes: [String: IMRuntimeRouteEndpointSet]
        let __wire_preferredEndpoints: [String: [String]]
        let __wire_routingPolicy: IMRuntimeRoutePolicy
        var __wire_environment: String? = nil
        var __wire_publicationID: String? = nil
        var __wire_publicationRevision: UInt64? = nil
        var __wire_profileFingerprint: String? = nil
        var __wire_lifetimeMode: IMSessionLifetimeMode? = nil
        var __wire_publicationStatus: String? = nil
        var __wire_keysetRevision: UInt64? = nil
        let __wire_accessDiagnosticsOverlayEnabled: Bool
        let __wire_phoneAuthEnabled: Bool
        let __wire_registrationEnabled: Bool
        let __wire_enterpriseCodeFirst: Bool
        let __wire_preferredEnterpriseCode: String
        __wire_appID = appID
        __wire_displayName = displayName
        __wire_platform = platform
        __wire_status = status
        __wire_domains = domains
        __wire_bootstrapHost = bootstrapHost
        __wire_appDomain = appDomain
        __wire_configVersion = configVersion
        __wire_ttlSeconds = ttlSeconds
        __wire_directory = directory
        __wire_legal = legal
        __wire_configHash = configHash
		__wire_contractVersion = contractVersion
		__wire_routeRevision = routeRevision
		__wire_routeSource = routeSource
		__wire_routeStatus = routeStatus
		__wire_routes = routes
		__wire_preferredEndpoints = preferredEndpoints
		__wire_routingPolicy = routingPolicy
        __wire_environment = environment
        __wire_publicationID = publicationID
        __wire_publicationRevision = publicationRevision
        __wire_profileFingerprint = profileFingerprint
        __wire_lifetimeMode = lifetimeMode
        __wire_publicationStatus = publicationStatus
        __wire_keysetRevision = keysetRevision
        __wire_accessDiagnosticsOverlayEnabled = accessDiagnosticsOverlayEnabled
        __wire_phoneAuthEnabled = phoneAuthEnabled
        __wire_registrationEnabled = registrationEnabled
        __wire_enterpriseCodeFirst = enterpriseCodeFirst
        __wire_preferredEnterpriseCode = preferredEnterpriseCode
        self.init(
            wireAppID: __wire_appID,
            displayName: __wire_displayName,
            platform: __wire_platform,
            status: __wire_status,
            domains: __wire_domains,
            bootstrapHost: __wire_bootstrapHost,
            appDomain: __wire_appDomain,
            configVersion: __wire_configVersion,
            ttlSeconds: __wire_ttlSeconds,
            directory: __wire_directory,
            legal: __wire_legal,
            configHash: __wire_configHash,
            contractVersion: __wire_contractVersion,
            routeRevision: __wire_routeRevision,
            routeSource: __wire_routeSource,
            routeStatus: __wire_routeStatus,
            routes: __wire_routes,
            preferredEndpoints: __wire_preferredEndpoints,
            routingPolicy: __wire_routingPolicy,
            environment: __wire_environment,
            publicationID: __wire_publicationID,
            publicationRevision: __wire_publicationRevision,
            profileFingerprint: __wire_profileFingerprint,
            lifetimeMode: __wire_lifetimeMode,
            publicationStatus: __wire_publicationStatus,
            keysetRevision: __wire_keysetRevision,
            accessDiagnosticsOverlayEnabled: __wire_accessDiagnosticsOverlayEnabled,
            phoneAuthEnabled: __wire_phoneAuthEnabled,
            registrationEnabled: __wire_registrationEnabled,
            enterpriseCodeFirst: __wire_enterpriseCodeFirst,
            preferredEnterpriseCode: __wire_preferredEnterpriseCode
        )
    }

    public init(from decoder: Decoder) throws {
        let appID: String
        let displayName: String
        let platform: String
        let status: String
        let domains: [String]
        let bootstrapHost: String
        let appDomain: String
        let configVersion: String
        let ttlSeconds: Int
        let directory: Directory
        let legal: Legal
        let configHash: String
        let contractVersion: Int
        let routeRevision: UInt64
        let routeSource: String
        let routeStatus: String
        let routes: [String: IMRuntimeRouteEndpointSet]
        let preferredEndpoints: [String: [String]]
        let routingPolicy: IMRuntimeRoutePolicy
        var environment: String? = nil
        var publicationID: String? = nil
        var publicationRevision: UInt64? = nil
        var profileFingerprint: String? = nil
        var lifetimeMode: IMSessionLifetimeMode? = nil
        var publicationStatus: String? = nil
        var keysetRevision: UInt64? = nil
        let accessDiagnosticsOverlayEnabled: Bool
        let phoneAuthEnabled: Bool
        let registrationEnabled: Bool
        let enterpriseCodeFirst: Bool
        let preferredEnterpriseCode: String
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let policyRoot = (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .policy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicy))
            ?? (try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .appPolicyCamel))
        let policySources = [policyRoot, c].compactMap { $0 }
        func firstConfiguredPolicyBool(_ keys: [CodingKeys]) -> Bool? {
            for source in policySources {
                for key in keys where source.contains(key) {
                    return source.decodeLossyBoolIfPresent(forKey: key) ?? false
                }
            }
            return nil
        }
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
            ?? c.decodeIfPresent(String.self, forKey: .appIDCamel)
            ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .displayNameCamel)
            ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        bootstrapHost = try c.decodeIfPresent(String.self, forKey: .bootstrapHost)
            ?? c.decodeIfPresent(String.self, forKey: .bootstrapHostCamel)
            ?? ""
        appDomain = try c.decodeIfPresent(String.self, forKey: .appDomain)
            ?? c.decodeIfPresent(String.self, forKey: .appDomainCamel)
            ?? ""
        configVersion = try c.decodeIfPresent(String.self, forKey: .configVersion)
            ?? c.decodeIfPresent(String.self, forKey: .configVersionCamel)
            ?? ""
        ttlSeconds = c.decodeLossyIntIfPresent(forKey: .ttlSeconds)
            ?? c.decodeLossyIntIfPresent(forKey: .ttlSecondsCamel)
            ?? 300
        directory = try c.decodeIfPresent(Directory.self, forKey: .directory) ?? Directory()
        legal = try c.decodeIfPresent(Legal.self, forKey: .legal) ?? Legal()
        configHash = try c.decodeIfPresent(String.self, forKey: .configHash)
            ?? c.decodeIfPresent(String.self, forKey: .configHashCamel)
            ?? ""
		contractVersion = try c.decodeIfPresent(Int.self, forKey: .contractVersion) ?? 0
		routeRevision = try c.decodeIfPresent(UInt64.self, forKey: .revision)
			?? c.decodeIfPresent(UInt64.self, forKey: .routeRevision) ?? 0
		routeSource = try c.decodeIfPresent(String.self, forKey: .routeSource) ?? ""
		routeStatus = try c.decodeIfPresent(String.self, forKey: .routeStatus) ?? ""
		routes = try c.decodeIfPresent([String: IMRuntimeRouteEndpointSet].self, forKey: .routes) ?? [:]
		preferredEndpoints = try c.decodeIfPresent([String: [String]].self, forKey: .preferredEndpoints) ?? [:]
		routingPolicy = try c.decodeIfPresent(IMRuntimeRoutePolicy.self, forKey: .routingPolicy) ?? .init(contractVersion: 0)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        publicationID = try c.decodeIfPresent(String.self, forKey: .publicationID)
        publicationRevision = try c.decodeIfPresent(UInt64.self, forKey: .publicationRevision)
        profileFingerprint = try c.decodeIfPresent(String.self, forKey: .profileFingerprint)
        lifetimeMode = .authoritativeValue(try c.decodeIfPresent(String.self, forKey: .lifetimeMode))
        if !c.contains(.lifetimeMode) { lifetimeMode = nil }
        publicationStatus = try c.decodeIfPresent(String.self, forKey: .publicationStatus)
            ?? (publicationID == nil ? nil : status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        keysetRevision = try c.decodeIfPresent(UInt64.self, forKey: .keysetRevision)
        let debugFeatures = try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeatures)
        let debugFeaturesCamel = try? c.nestedContainer(keyedBy: DebugFeaturesCodingKeys.self, forKey: .debugFeaturesCamel)
        accessDiagnosticsOverlayEnabled = c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? debugFeatures?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? debugFeaturesCamel?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabled)
            ?? debugFeaturesCamel?.decodeLossyBoolIfPresent(forKey: .accessDiagnosticsOverlayEnabledCamel)
            ?? false
        let primary = policyRoot ?? c
        let authPolicy = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicy))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicy))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .authPolicyCamel))
        let registerPolicy = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicy))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicy))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .registerPolicyCamel))
        let loginPolicy = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicy))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicyCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicy))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .loginPolicyCamel))
        let tenantPool = (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPool))
            ?? (try? primary.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPoolCamel))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPool))
            ?? (try? c.nestedContainer(keyedBy: AppAuthPolicyCodingKeys.self, forKey: .tenantPoolCamel))
        let nestedPolicySources = [authPolicy, registerPolicy, loginPolicy, tenantPool].compactMap { $0 }
        func firstNestedConfiguredPolicyBool(_ keys: [AppAuthPolicyCodingKeys]) -> Bool? {
            for source in nestedPolicySources {
                for key in keys where source.contains(key) {
                    return source.decodeLossyBoolIfPresent(forKey: key) ?? false
                }
            }
            return nil
        }
        phoneAuthEnabled = policyRoot?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? policyRoot?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? c.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? c.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? authPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? authPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? registerPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? registerPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? loginPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? loginPolicy?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? tenantPool?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabled)
            ?? tenantPool?.decodeLossyBoolIfPresent(forKey: .phoneAuthEnabledCamel)
            ?? true
        registrationEnabled = firstConfiguredPolicyBool([
            .registrationEnabled, .registrationEnabledCamel, .openRegistration, .openRegistrationCamel
        ])
            ?? firstNestedConfiguredPolicyBool([
                .registrationEnabled, .registrationEnabledCamel, .openRegistration, .openRegistrationCamel
            ])
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .enabled)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpen)
            ?? registerPolicy?.decodeConfiguredBoolIfPresent(forKey: .registrationOpenCamel)
            ?? true
        enterpriseCodeFirst = firstConfiguredPolicyBool([
            .enterpriseCodeFirst, .enterpriseCodeFirstCamel, .preferEnterpriseCode, .preferEnterpriseCodeCamel
        ])
            ?? firstNestedConfiguredPolicyBool([
                .enterpriseCodeFirst, .enterpriseCodeFirstCamel, .preferEnterpriseCode, .preferEnterpriseCodeCamel
            ])
            ?? false
        let rawPreferred = try c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCode)
            ?? c.decodeIfPresent(String.self, forKey: .preferredEnterpriseCodeCamel)
            ?? ""
        preferredEnterpriseCode = Self.validPreferredEnterpriseCode(
            rawPreferred,
            appID: appID,
            enterpriseCodeFirst: enterpriseCodeFirst
        )
        self.init(
            wireAppID: appID,
            displayName: displayName,
            platform: platform,
            status: status,
            domains: domains,
            bootstrapHost: bootstrapHost,
            appDomain: appDomain,
            configVersion: configVersion,
            ttlSeconds: ttlSeconds,
            directory: directory,
            legal: legal,
            configHash: configHash,
            contractVersion: contractVersion,
            routeRevision: routeRevision,
            routeSource: routeSource,
            routeStatus: routeStatus,
            routes: routes,
            preferredEndpoints: preferredEndpoints,
            routingPolicy: routingPolicy,
            environment: environment,
            publicationID: publicationID,
            publicationRevision: publicationRevision,
            profileFingerprint: profileFingerprint,
            lifetimeMode: lifetimeMode,
            publicationStatus: publicationStatus,
            keysetRevision: keysetRevision,
            accessDiagnosticsOverlayEnabled: accessDiagnosticsOverlayEnabled,
            phoneAuthEnabled: phoneAuthEnabled,
            registrationEnabled: registrationEnabled,
            enterpriseCodeFirst: enterpriseCodeFirst,
            preferredEnterpriseCode: preferredEnterpriseCode
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appID, forKey: .appID)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(platform, forKey: .platform)
        try c.encode(status, forKey: .status)
        try c.encode(domains, forKey: .domains)
        try c.encode(bootstrapHost, forKey: .bootstrapHost)
        try c.encode(appDomain, forKey: .appDomain)
        try c.encode(configVersion, forKey: .configVersion)
        try c.encode(ttlSeconds, forKey: .ttlSeconds)
        try c.encode(directory, forKey: .directory)
        try c.encode(legal, forKey: .legal)
        try c.encode(configHash, forKey: .configHash)
		try c.encode(contractVersion, forKey: .contractVersion)
		try c.encode(routeRevision, forKey: .revision)
		try c.encode(routeSource, forKey: .routeSource)
		try c.encode(routeStatus, forKey: .routeStatus)
		try c.encode(routes, forKey: .routes)
		try c.encode(preferredEndpoints, forKey: .preferredEndpoints)
		try c.encode(routingPolicy, forKey: .routingPolicy)
        try c.encodeIfPresent(environment, forKey: .environment)
        try c.encodeIfPresent(publicationID, forKey: .publicationID)
        try c.encodeIfPresent(publicationRevision, forKey: .publicationRevision)
        try c.encodeIfPresent(profileFingerprint, forKey: .profileFingerprint)
        try c.encodeIfPresent(lifetimeMode, forKey: .lifetimeMode)
        try c.encodeIfPresent(publicationStatus, forKey: .publicationStatus)
        try c.encodeIfPresent(keysetRevision, forKey: .keysetRevision)
        try c.encode(accessDiagnosticsOverlayEnabled, forKey: .accessDiagnosticsOverlayEnabled)
        try c.encode(phoneAuthEnabled, forKey: .phoneAuthEnabled)
        try c.encode(registrationEnabled, forKey: .registrationEnabled)
        try c.encode(enterpriseCodeFirst, forKey: .enterpriseCodeFirst)
        if !preferredEnterpriseCode.isEmpty {
            try c.encode(preferredEnterpriseCode, forKey: .preferredEnterpriseCode)
        }
    }

    var normalizedAppID: String {
        IMAPIContext.normalizedIOSAppID(appID)
    }

    var normalizedConfigVersion: String {
        configVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validPreferredEnterpriseCode(_ rawValue: String, appID: String, enterpriseCodeFirst: Bool) -> String {
        guard enterpriseCodeFirst else { return "" }
        let exactAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedAppIDs = Set([IMAPIContext.canonicalIOSAppID, "jht-ios-main", "ios-main"])
        guard allowedAppIDs.contains(exactAppID) else { return "" }
        guard let entry = RegistrationFlowPolicy.normalizedEntryCode(rawValue),
              entry.kind == .enterprise else { return "" }
        return entry.normalizedValue
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

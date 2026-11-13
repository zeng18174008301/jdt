import Foundation
import IM4Domain

// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_BEGIN
public struct RemoteAppBootstrap: Equatable, Sendable {
    public struct Directory: Codable, Equatable, Sendable {
        public let apiBaseURL: String
        public let endpoints: [String]
        public let fallbackDomains: [String]
        public let status: String

        enum CodingKeys: String, CodingKey {
            case apiBaseURL = "api_base_url"
            case apiBaseURLCamel = "apiBaseUrl"
            case endpoints
            case fallbackDomains = "fallback_domains"
            case fallbackDomainsCamel = "fallbackDomains"
            case status
        }

        public init(apiBaseURL: String = "", endpoints: [String] = [], fallbackDomains: [String] = [], status: String = "") {
            self.apiBaseURL = apiBaseURL
            self.endpoints = endpoints
            self.fallbackDomains = fallbackDomains
            self.status = status
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL)
                ?? c.decodeIfPresent(String.self, forKey: .apiBaseURLCamel)
                ?? ""
            endpoints = try c.decodeIfPresent([String].self, forKey: .endpoints) ?? []
            fallbackDomains = try c.decodeIfPresent([String].self, forKey: .fallbackDomains)
                ?? c.decodeIfPresent([String].self, forKey: .fallbackDomainsCamel)
                ?? []
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(apiBaseURL, forKey: .apiBaseURL)
            try c.encode(endpoints, forKey: .endpoints)
            try c.encode(fallbackDomains, forKey: .fallbackDomains)
            try c.encode(status, forKey: .status)
        }
    }

    public struct Legal: Codable, Equatable, Sendable {
        public let legalDocsURL: String
        public let manifestURL: String

        enum CodingKeys: String, CodingKey {
            case legalDocsURL = "legal_docs_url"
            case legalDocsURLCamel = "legalDocsUrl"
            case manifestURL = "manifest_url"
            case manifestURLCamel = "manifestUrl"
        }

        public init(legalDocsURL: String = "", manifestURL: String = "") {
            self.legalDocsURL = legalDocsURL
            self.manifestURL = manifestURL
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            legalDocsURL = try c.decodeIfPresent(String.self, forKey: .legalDocsURL)
                ?? c.decodeIfPresent(String.self, forKey: .legalDocsURLCamel)
                ?? ""
            manifestURL = try c.decodeIfPresent(String.self, forKey: .manifestURL)
                ?? c.decodeIfPresent(String.self, forKey: .manifestURLCamel)
                ?? ""
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(legalDocsURL, forKey: .legalDocsURL)
            try c.encode(manifestURL, forKey: .manifestURL)
        }
    }

    public let appID: String

    public let displayName: String

    public let platform: String

    public let status: String

    public let domains: [String]

    public let bootstrapHost: String

    public let appDomain: String

    public let configVersion: String

    public let ttlSeconds: Int

    public let directory: Directory

    public let legal: Legal

    public let configHash: String

	public let contractVersion: Int

	public let routeRevision: UInt64

	public let routeSource: String

	public let routeStatus: String

	public let routes: [String: IMRuntimeRouteEndpointSet]

	public let preferredEndpoints: [String: [String]]

	public let routingPolicy: IMRuntimeRoutePolicy

    public var environment: String? = nil

    public var publicationID: String? = nil

    public var publicationRevision: UInt64? = nil

    public var profileFingerprint: String? = nil

    public var lifetimeMode: IMSessionLifetimeMode? = nil

    public var publicationStatus: String? = nil

    public var keysetRevision: UInt64? = nil

    public let accessDiagnosticsOverlayEnabled: Bool

    public let phoneAuthEnabled: Bool

    public let registrationEnabled: Bool

    public let enterpriseCodeFirst: Bool

    public let preferredEnterpriseCode: String

    public init(
        wireAppID appID: String,
        displayName: String,
        platform: String,
        status: String,
        domains: [String],
        bootstrapHost: String,
        appDomain: String,
        configVersion: String,
        ttlSeconds: Int,
        directory: Directory,
        legal: Legal,
        configHash: String,
        contractVersion: Int,
        routeRevision: UInt64,
        routeSource: String,
        routeStatus: String,
        routes: [String: IMRuntimeRouteEndpointSet],
        preferredEndpoints: [String: [String]],
        routingPolicy: IMRuntimeRoutePolicy,
        environment: String? = nil,
        publicationID: String? = nil,
        publicationRevision: UInt64? = nil,
        profileFingerprint: String? = nil,
        lifetimeMode: IMSessionLifetimeMode? = nil,
        publicationStatus: String? = nil,
        keysetRevision: UInt64? = nil,
        accessDiagnosticsOverlayEnabled: Bool,
        phoneAuthEnabled: Bool,
        registrationEnabled: Bool,
        enterpriseCodeFirst: Bool,
        preferredEnterpriseCode: String
    ) {
        self.appID = appID
        self.displayName = displayName
        self.platform = platform
        self.status = status
        self.domains = domains
        self.bootstrapHost = bootstrapHost
        self.appDomain = appDomain
        self.configVersion = configVersion
        self.ttlSeconds = ttlSeconds
        self.directory = directory
        self.legal = legal
        self.configHash = configHash
        self.contractVersion = contractVersion
        self.routeRevision = routeRevision
        self.routeSource = routeSource
        self.routeStatus = routeStatus
        self.routes = routes
        self.preferredEndpoints = preferredEndpoints
        self.routingPolicy = routingPolicy
        self.environment = environment
        self.publicationID = publicationID
        self.publicationRevision = publicationRevision
        self.profileFingerprint = profileFingerprint
        self.lifetimeMode = lifetimeMode
        self.publicationStatus = publicationStatus
        self.keysetRevision = keysetRevision
        self.accessDiagnosticsOverlayEnabled = accessDiagnosticsOverlayEnabled
        self.phoneAuthEnabled = phoneAuthEnabled
        self.registrationEnabled = registrationEnabled
        self.enterpriseCodeFirst = enterpriseCodeFirst
        self.preferredEnterpriseCode = preferredEnterpriseCode
    }
}
// WDT_IOS1_DATA_REMAINING_NETWORK_WIRE_20261111_END

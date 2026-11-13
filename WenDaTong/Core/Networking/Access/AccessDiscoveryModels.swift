import CryptoKit
import Foundation
import Network

struct RemoteAccessDiscoveryResponse: Codable, Equatable, Sendable {
    let contractVersion: Int
    let configVersion: String
    let serverTime: Int
    let ttlSeconds: Int
    let refreshJitterSeconds: Int
    let source: String
    let stale: Bool
    let degraded: Bool
    let endpoints: [RemoteAccessDiscoveryEndpoint]
    let discoveryFallbacks: [RemoteAccessDiscoveryEndpoint]
    let signatureAlg: String?
    let signature: String?
    let trust: AccessDiscoveryTrustProof?
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion = "contract_version"
        case configVersion = "config_version"
        case serverTime = "server_time"
        case ttlSeconds = "ttl_seconds"
        case refreshJitterSeconds = "refresh_jitter_seconds"
        case source
        case stale
        case degraded
        case endpoints
        case discoveryFallbacks = "discovery_fallbacks"
        case signatureAlg = "signature_alg"
        case signature
        case trust
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "status"
        case keysetRevision = "keyset_revision"
    }

    init(
        contractVersion: Int,
        configVersion: String,
        serverTime: Int,
        ttlSeconds: Int,
        refreshJitterSeconds: Int,
        source: String,
        stale: Bool,
        degraded: Bool,
        endpoints: [RemoteAccessDiscoveryEndpoint],
        discoveryFallbacks: [RemoteAccessDiscoveryEndpoint],
        signatureAlg: String?,
        signature: String?,
        trust: AccessDiscoveryTrustProof? = nil,
        publicationID: String? = nil,
        publicationRevision: UInt64? = nil,
        profileFingerprint: String? = nil,
        lifetimeMode: IMSessionLifetimeMode? = nil,
        publicationStatus: String? = nil,
        keysetRevision: UInt64? = nil
    ) {
        self.contractVersion = contractVersion
        self.configVersion = configVersion
        self.serverTime = serverTime
        self.ttlSeconds = ttlSeconds
        self.refreshJitterSeconds = refreshJitterSeconds
        self.source = source
        self.stale = stale
        self.degraded = degraded
        self.endpoints = endpoints
        self.discoveryFallbacks = discoveryFallbacks
        self.signatureAlg = signatureAlg
        self.signature = signature
        self.trust = trust
        self.publicationID = publicationID
        self.publicationRevision = publicationRevision
        self.profileFingerprint = profileFingerprint
        self.lifetimeMode = lifetimeMode
        self.publicationStatus = publicationStatus
        self.keysetRevision = keysetRevision
    }
}

struct AccessDiscoveryTrustProof: Codable, Equatable, Sendable {
    let payloadB64: String
    let keyID: String
    let signatureAlg: String
    let signature: String
    let keyState: SignedAccessDiscoveryKeyState
    let generation: UInt64
    let fencingGeneration: UInt64
    let recoveryGeneration: UInt64
    let keyStateHash: String
    let keyStateExpiresAt: String
    let contentHash: String
    let issuedAt: String
    let expiresAt: String
    let environment: String
    let productID: String
    let appID: String
    let channel: String
    let clientIdentifier: String
    let tenantID: String
    let platform: String
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var publicationStatus: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case payloadB64 = "payload_b64"
        case keyID = "key_id"
        case signatureAlg = "signature_alg"
        case signature
        case keyState = "key_state"
        case generation
        case fencingGeneration = "fencing_generation"
        case recoveryGeneration = "recovery_generation"
        case keyStateHash = "key_state_hash"
        case keyStateExpiresAt = "key_state_expires_at"
        case contentHash = "content_hash"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case environment
        case productID = "product_id"
        case channel
        case clientIdentifier = "client_identifier"
        case tenantID = "tenant_id"
        case appID = "app_id"
        case platform
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case publicationStatus = "status"
        case keysetRevision = "keyset_revision"
    }
}

struct SignedAccessDiscoveryEnvelope: Codable, Sendable {
    let payloadB64: String
    let keyID: String
    let signatureAlg: String
    let signature: String
    let keyState: SignedAccessDiscoveryKeyState

    enum CodingKeys: String, CodingKey, CaseIterable {
        case payloadB64 = "payload_b64"
        case keyID = "key_id"
        case signatureAlg = "signature_alg"
        case signature
        case keyState = "key_state"
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AccessDiscoveryDynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadB64 = try container.decode(String.self, forKey: .payloadB64)
        keyID = try container.decode(String.self, forKey: .keyID)
        signatureAlg = try container.decode(String.self, forKey: .signatureAlg)
        signature = try container.decode(String.self, forKey: .signature)
        keyState = try container.decode(SignedAccessDiscoveryKeyState.self, forKey: .keyState)
    }
}

struct SignedAccessDiscoveryKeyState: Codable, Equatable, Sendable {
    let payloadB64: String
    let rootKeyID: String
    let signatureAlg: String
    let signature: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case payloadB64 = "payload_b64"
        case rootKeyID = "root_key_id"
        case signatureAlg = "signature_alg"
        case signature
    }

    init(payloadB64: String, rootKeyID: String, signatureAlg: String, signature: String) {
        self.payloadB64 = payloadB64
        self.rootKeyID = rootKeyID
        self.signatureAlg = signatureAlg
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AccessDiscoveryDynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadB64 = try container.decode(String.self, forKey: .payloadB64)
        rootKeyID = try container.decode(String.self, forKey: .rootKeyID)
        signatureAlg = try container.decode(String.self, forKey: .signatureAlg)
        signature = try container.decode(String.self, forKey: .signature)
    }
}

struct AccessDiscoveryKeyAuthorization: Codable, Equatable, Sendable {
    let keyID: String
    let algorithm: String
    let role: String
    let status: String
    let environment: String
    let productID: String
    let appID: String
    let platform: String
    let channel: String
    let clientIdentifier: String
    let notBefore: String
    let notAfter: String
    let minFencingGeneration: UInt64
    let maxFencingGeneration: UInt64?

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case algorithm, role, status, environment
        case productID = "product_id"
        case appID = "app_id"
        case platform, channel
        case clientIdentifier = "client_identifier"
        case notBefore = "not_before"
        case notAfter = "not_after"
        case minFencingGeneration = "min_fencing_generation"
        case maxFencingGeneration = "max_fencing_generation"
    }
}

struct AccessDiscoveryKeyStatePayload: Codable, Equatable, Sendable {
    let purpose: String
    let contractVersion: Int
    let recoveryGeneration: UInt64
    let currentFencingGeneration: UInt64
    let issuedAt: String
    let expiresAt: String
    let keys: [AccessDiscoveryKeyAuthorization]
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case purpose, keys
        case contractVersion = "contract_version"
        case recoveryGeneration = "recovery_generation"
        case currentFencingGeneration = "current_fencing_generation"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case keysetRevision = "keyset_revision"
    }
}

private struct AccessDiscoveryDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct SignedAccessDiscoveryPayload: Codable, Equatable, Sendable {
    let purpose: String
    let contractVersion: Int
    let canonicalizationVersion: Int
    let tenantID: String
    let appID: String
    let platform: String
    let environment: String
    let productID: String
    let channel: String
    let clientIdentifier: String
    let fencingGeneration: UInt64
    let generation: UInt64
    let configVersion: String
    let issuedAt: String
    let expiresAt: String
    let serverTime: Int
    let ttlSeconds: Int
    let refreshJitterSeconds: Int
    let source: String
    let stale: Bool
    let degraded: Bool
    let contentHash: String
    let endpoints: [RemoteAccessDiscoveryEndpoint]
    let discoveryFallbacks: [RemoteAccessDiscoveryEndpoint]
    var publicationID: String? = nil
    var publicationRevision: UInt64? = nil
    var profileFingerprint: String? = nil
    var lifetimeMode: IMSessionLifetimeMode? = nil
    var status: String? = nil
    var keysetRevision: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case purpose
        case contractVersion = "contract_version"
        case canonicalizationVersion = "canonicalization_version"
        case tenantID = "tenant_id"
        case appID = "app_id"
        case platform
        case environment
        case productID = "product_id"
        case channel
        case clientIdentifier = "client_identifier"
        case fencingGeneration = "fencing_generation"
        case generation
        case configVersion = "config_version"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case serverTime = "server_time"
        case ttlSeconds = "ttl_seconds"
        case refreshJitterSeconds = "refresh_jitter_seconds"
        case source
        case stale
        case degraded
        case contentHash = "content_hash"
        case endpoints
        case discoveryFallbacks = "discovery_fallbacks"
        case publicationID = "publication_id"
        case publicationRevision = "publication_revision"
        case profileFingerprint = "profile_fingerprint"
        case lifetimeMode = "lifetime_mode"
        case status
        case keysetRevision = "keyset_revision"
    }
}

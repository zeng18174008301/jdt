import CryptoKit
import Foundation

enum PreloginBootstrapError: String, Error, Equatable {
    case invalidJSON = "prelogin_bootstrap_invalid_json"
    case duplicateJSONKey = "prelogin_bootstrap_duplicate_json_key"
    case nonCanonicalJSON = "prelogin_bootstrap_non_canonical_json"
    case invalidContract = "prelogin_bootstrap_invalid_contract"
    case scopeMismatch = "prelogin_bootstrap_scope_mismatch"
    case notYetValid = "prelogin_bootstrap_not_yet_valid"
    case expired = "prelogin_bootstrap_expired"
    case lifetimeTooLong = "prelogin_bootstrap_lifetime_too_long"
    case signingPayloadTooLarge = "prelogin_bootstrap_signing_payload_too_large"
    case contentHashMismatch = "prelogin_bootstrap_content_hash_mismatch"
    case signatureInvalid = "prelogin_bootstrap_signature_invalid"
    case untrustedRecoveryRoot = "prelogin_bootstrap_untrusted_recovery_root"
    case keyUnauthorized = "prelogin_bootstrap_key_unauthorized"
    case candidateConflict = "prelogin_bootstrap_candidate_conflict"
    case noValidCandidate = "prelogin_bootstrap_no_valid_candidate"
    case recoveryRollback = "prelogin_bootstrap_recovery_state_rollback"
    case recoveryConflict = "prelogin_bootstrap_recovery_state_conflict"
    case currentPointerInvalid = "prelogin_bootstrap_current_pointer_invalid"
    case clockRollback = "prelogin_bootstrap_clock_rollback"
    case allSourcesUnavailable = "prelogin_bootstrap_all_sources_unavailable"
    case configurationBlocked = "prelogin_bootstrap_configuration_blocked"
}

struct PreloginAudience: Codable, Equatable, Sendable {
    let productID: String
    let appID: String
    let bundleID: String?
    let packageName: String?
    let channel: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case appID = "app_id"
        case bundleID = "bundle_id"
        case packageName = "package_name"
        case channel, platform
    }
}

struct PreloginEndpoint: Codable, Equatable, Sendable {
    let id: String
    let usage: String
    let `protocol`: String
    let url: String
    let host: String
    let port: Int
    let path: String
    let priority: Int
}

struct PreloginPayload: Codable, Equatable, Sendable {
    let purpose: String
    let environment: String
    let audience: PreloginAudience
    let contractVersion: Int
    let canonicalizationVersion: Int
    let keyID: String
    let fencingGeneration: UInt64
    let configVersion: UInt64
    let issuedAt: String
    let expiresAt: String
    let contentHash: String
    let endpoints: [PreloginEndpoint]

    enum CodingKeys: String, CodingKey {
        case purpose, environment, audience
        case contractVersion = "contract_version"
        case canonicalizationVersion = "canonicalization_version"
        case keyID = "key_id"
        case fencingGeneration = "fencing_generation"
        case configVersion = "config_version"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case contentHash = "content_hash"
        case endpoints
    }
}

struct PreloginArtifact: Codable, Equatable, Sendable {
    let payload: PreloginPayload
    let signatureAlg: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case payload, signature
        case signatureAlg = "signature_alg"
    }
}

struct PreloginKeyAuthorization: Codable, Equatable, Sendable {
    let keyID: String
    let algorithm: String
    let status: String
    let environment: String
    let productID: String
    let appID: String
    let bundleID: String?
    let packageName: String?
    let channel: String
    let platform: String
    let minFencingGeneration: UInt64
    let maxFencingGeneration: UInt64?

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case algorithm, status, environment
        case productID = "product_id"
        case appID = "app_id"
        case bundleID = "bundle_id"
        case packageName = "package_name"
        case channel, platform
        case minFencingGeneration = "min_fencing_generation"
        case maxFencingGeneration = "max_fencing_generation"
    }
}

struct PreloginKeyStatePayload: Codable, Equatable, Sendable {
    let purpose: String
    let contractVersion: Int
    let recoveryGeneration: UInt64
    let currentFencingGeneration: UInt64
    let issuedAt: String
    let expiresAt: String
    let keys: [PreloginKeyAuthorization]

    enum CodingKeys: String, CodingKey {
        case purpose, keys
        case contractVersion = "contract_version"
        case recoveryGeneration = "recovery_generation"
        case currentFencingGeneration = "current_fencing_generation"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

struct PreloginSignedKeyState: Codable, Equatable, Sendable {
    let payload: PreloginKeyStatePayload
    let rootKeyID: String
    let signatureAlg: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case payload, signature
        case rootKeyID = "root_key_id"
        case signatureAlg = "signature_alg"
    }
}

struct PreloginCurrentPayload: Codable, Equatable, Sendable {
    let purpose: String
    let scopeHash: String
    let keyStateKey: String
    let keyStateHash: String
    let artifactKey: String
    let artifactHash: String
    let artifactPayloadHash: String
    let fencingGeneration: UInt64
    let configVersion: UInt64
    let issuedAt: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case purpose
        case scopeHash = "scope_hash"
        case keyStateKey = "key_state_key"
        case keyStateHash = "key_state_hash"
        case artifactKey = "artifact_key"
        case artifactHash = "artifact_hash"
        case artifactPayloadHash = "artifact_payload_hash"
        case fencingGeneration = "fencing_generation"
        case configVersion = "config_version"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

struct PreloginSignedCurrent: Codable, Equatable, Sendable {
    let payload: PreloginCurrentPayload
    let keyID: String
    let signatureAlg: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case payload, signature
        case keyID = "key_id"
        case signatureAlg = "signature_alg"
    }
}

struct PreloginExpectedScope: Equatable, Sendable {
    let environment: String
    let productID: String
    let appID: String
    let bundleID: String
    let channel: String
    let platform: String

    var audience: PreloginAudience {
        PreloginAudience(
            productID: productID,
            appID: appID,
            bundleID: bundleID,
            packageName: nil,
            channel: channel,
            platform: platform
        )
    }
}
struct PreloginVerifiedArtifact: Sendable {
    let raw: Data
    let artifact: PreloginArtifact
    let canonicalPayload: Data
    let payloadHash: String
}

struct PreloginVerifiedKeyState: Sendable {
    let raw: Data
    let state: PreloginSignedKeyState
    let canonicalPayload: Data
    let payloadHash: String
    let objectHash: String
    let authorizations: [String: PreloginKeyAuthorization]
}

struct PreloginVerifiedCurrent: Sendable {
    let raw: Data
    let pointer: PreloginSignedCurrent
}

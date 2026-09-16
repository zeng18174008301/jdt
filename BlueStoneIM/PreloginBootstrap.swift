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

private struct PreloginScopeHashContract: Encodable {
    let environment: String
    let productID: String
    let appID: String
    let bundleID: String?
    let packageName: String?
    let channel: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case environment
        case productID = "product_id"
        case appID = "app_id"
        case bundleID = "bundle_id"
        case packageName = "package_name"
        case channel, platform
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

// MARK: - Strict Go-compatible canonical JSON

private indirect enum PreloginJSONValue {
    case object([(String, PreloginJSONValue)])
    case array([PreloginJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    var objectMembers: [(String, PreloginJSONValue)]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayMembers: [PreloginJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}

private struct PreloginJSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    init(_ raw: Data) {
        bytes = Array(raw)
    }

    mutating func parse() throws -> PreloginJSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw PreloginBootstrapError.invalidJSON }
        return value
    }

    private mutating func parseValue() throws -> PreloginJSONValue {
        guard index < bytes.count else { throw PreloginBootstrapError.invalidJSON }
        switch bytes[index] {
        case 0x7B:
            return try parseObject()
        case 0x5B:
            return try parseArray()
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .boolean(true)
        case 0x66:
            try consumeLiteral("false")
            return .boolean(false)
        case 0x6E:
            try consumeLiteral("null")
            return .null
        case 0x2D, 0x30...0x39:
            return .number(try parseInteger())
        default:
            throw PreloginBootstrapError.invalidJSON
        }
    }

    private mutating func parseObject() throws -> PreloginJSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        skipWhitespace()
        var members: [(String, PreloginJSONValue)] = []
        var keys = Set<String>()
        if consume(0x7D) { return .object(members) }
        while true {
            guard peek() == 0x22 else { throw PreloginBootstrapError.invalidJSON }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw PreloginBootstrapError.duplicateJSONKey }
            skipWhitespace()
            guard consume(0x3A) else { throw PreloginBootstrapError.invalidJSON }
            skipWhitespace()
            members.append((key, try parseValue()))
            skipWhitespace()
            if consume(0x7D) { break }
            guard consume(0x2C) else { throw PreloginBootstrapError.invalidJSON }
            skipWhitespace()
        }
        return .object(members)
    }

    private mutating func parseArray() throws -> PreloginJSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        skipWhitespace()
        var members: [PreloginJSONValue] = []
        if consume(0x5D) { return .array(members) }
        while true {
            members.append(try parseValue())
            skipWhitespace()
            if consume(0x5D) { break }
            guard consume(0x2C) else { throw PreloginBootstrapError.invalidJSON }
            skipWhitespace()
        }
        return .array(members)
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw PreloginBootstrapError.invalidJSON }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if !escaped, byte == 0x22 {
                index += 1
                let raw = Data(bytes[start..<index])
                guard let decoded = try JSONSerialization.jsonObject(
                    with: raw,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw PreloginBootstrapError.invalidJSON
                }
                return decoded
            }
            if !escaped, byte < 0x20 { throw PreloginBootstrapError.invalidJSON }
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            }
            index += 1
        }
        throw PreloginBootstrapError.invalidJSON
    }

    private mutating func parseInteger() throws -> String {
        let start = index
        if consume(0x2D) {
            guard index < bytes.count else { throw PreloginBootstrapError.invalidJSON }
        }
        if consume(0x30) {
            guard index == bytes.count || !(0x30...0x39).contains(bytes[index]) else {
                throw PreloginBootstrapError.nonCanonicalJSON
            }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw PreloginBootstrapError.invalidJSON
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x2E || bytes[index] == 0x45 || bytes[index] == 0x65 {
            throw PreloginBootstrapError.nonCanonicalJSON
        }
        guard let number = String(data: Data(bytes[start..<index]), encoding: .utf8) else {
            throw PreloginBootstrapError.invalidJSON
        }
        return number
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = Array("\(literal)".utf8)
        guard bytes[index...].starts(with: expected) else { throw PreloginBootstrapError.invalidJSON }
        index += expected.count
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= PreloginStrictJSON.maxDepth else { throw PreloginBootstrapError.invalidJSON }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }
}

enum PreloginStrictJSON {
    static let maxBytes = 256 * 1024
    static let maxDepth = 16

    static func decodeArtifact(_ raw: Data) throws -> PreloginArtifact {
        try decode(PreloginArtifact.self, from: raw, schema: .artifact)
    }

    static func decodeKeyState(_ raw: Data) throws -> PreloginSignedKeyState {
        try decode(PreloginSignedKeyState.self, from: raw, schema: .keyState)
    }

    static func decodeCurrent(_ raw: Data) throws -> PreloginSignedCurrent {
        try decode(PreloginSignedCurrent.self, from: raw, schema: .current)
    }

    static func decodeAccessDiscoveryPayload(_ raw: Data) throws -> SignedAccessDiscoveryPayload {
        try decode(SignedAccessDiscoveryPayload.self, from: raw, schema: .accessDiscoveryPayload)
    }

    static func decodeAccessDiscoveryKeyStatePayload(_ raw: Data) throws -> AccessDiscoveryKeyStatePayload {
        try decode(AccessDiscoveryKeyStatePayload.self, from: raw, schema: .accessDiscoveryKeyStatePayload)
    }

    static func accessDiscoveryExecutableHash(_ raw: Data) throws -> String {
        guard !raw.isEmpty, raw.count <= maxBytes else { throw PreloginBootstrapError.invalidJSON }
        var parser = PreloginJSONParser(raw)
        let value = try parser.parse()
        guard try render(value) == raw else { throw PreloginBootstrapError.nonCanonicalJSON }
        let payload = try exactObject(
            value,
            required: accessDiscoveryPayloadRequiredKeys,
            optional: accessDiscoveryPayloadV2Keys
        )
        let executable = PreloginJSONValue.object([
            ("endpoints", try member("endpoints", in: payload)),
            ("discovery_fallbacks", try member("discovery_fallbacks", in: payload))
        ])
        return PreloginTrust.sha256(try render(executable))
    }

    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(value)
        } catch {
            throw PreloginBootstrapError.invalidJSON
        }
        var parser = PreloginJSONParser(encoded)
        return try render(parser.parse())
    }

    private enum Schema {
        case artifact
        case keyState
        case current
        case accessDiscoveryPayload
        case accessDiscoveryKeyStatePayload
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from raw: Data,
        schema: Schema
    ) throws -> T {
        guard !raw.isEmpty, raw.count <= maxBytes else { throw PreloginBootstrapError.invalidJSON }
        var parser = PreloginJSONParser(raw)
        let value = try parser.parse()
        try validateShape(value, schema: schema)
        guard try render(value) == raw else { throw PreloginBootstrapError.nonCanonicalJSON }
        do {
            return try JSONDecoder().decode(type, from: raw)
        } catch {
            throw PreloginBootstrapError.invalidJSON
        }
    }

    private static func validateShape(_ value: PreloginJSONValue, schema: Schema) throws {
        switch schema {
        case .artifact:
            let artifact = try exactObject(value, required: ["payload", "signature_alg", "signature"])
            try requireStrings(["signature_alg", "signature"], in: artifact)
            let payload = try exactObject(
                try member("payload", in: artifact),
                required: [
                    "purpose", "environment", "audience", "contract_version",
                    "canonicalization_version", "key_id", "fencing_generation",
                    "config_version", "issued_at", "expires_at", "content_hash", "endpoints"
                ]
            )
            try requireStrings(
                [
                    "purpose", "environment", "key_id", "issued_at", "expires_at",
                    "content_hash"
                ],
                in: payload
            )
            try requireNumbers(
                ["contract_version", "canonicalization_version", "fencing_generation", "config_version"],
                in: payload
            )
            let audience = try exactObject(
                try member("audience", in: payload),
                required: ["product_id", "app_id", "channel", "platform"],
                optional: ["bundle_id", "package_name"]
            )
            try requireStrings(["product_id", "app_id", "channel", "platform"], in: audience)
            try requireOptionalStrings(["bundle_id", "package_name"], in: audience)
            guard let endpoints = try member("endpoints", in: payload).arrayMembers else {
                throw PreloginBootstrapError.invalidJSON
            }
            for endpoint in endpoints {
                let members = try exactObject(
                    endpoint,
                    required: ["id", "usage", "protocol", "url", "host", "port", "path", "priority"]
                )
                try requireStrings(["id", "usage", "protocol", "url", "host", "path"], in: members)
                try requireNumbers(["port", "priority"], in: members)
            }
        case .keyState:
            let state = try exactObject(
                value,
                required: ["payload", "root_key_id", "signature_alg", "signature"]
            )
            try requireStrings(["root_key_id", "signature_alg", "signature"], in: state)
            let payload = try exactObject(
                try member("payload", in: state),
                required: [
                    "purpose", "contract_version", "recovery_generation",
                    "current_fencing_generation", "issued_at", "expires_at", "keys"
                ]
            )
            try requireStrings(["purpose", "issued_at", "expires_at"], in: payload)
            try requireNumbers(
                ["contract_version", "recovery_generation", "current_fencing_generation"],
                in: payload
            )
            guard let keys = try member("keys", in: payload).arrayMembers else {
                throw PreloginBootstrapError.invalidJSON
            }
            for key in keys {
                let members = try exactObject(
                    key,
                    required: [
                        "key_id", "algorithm", "status", "environment", "product_id",
                        "app_id", "channel", "platform", "min_fencing_generation"
                    ],
                    optional: ["bundle_id", "package_name", "max_fencing_generation"]
                )
                try requireStrings(
                    [
                        "key_id", "algorithm", "status", "environment", "product_id",
                        "app_id", "channel", "platform"
                    ],
                    in: members
                )
                try requireOptionalStrings(["bundle_id", "package_name"], in: members)
                try requireNumbers(["min_fencing_generation"], in: members)
                try requireOptionalNumbers(["max_fencing_generation"], in: members)
            }
        case .current:
            let current = try exactObject(
                value,
                required: ["payload", "key_id", "signature_alg", "signature"]
            )
            try requireStrings(["key_id", "signature_alg", "signature"], in: current)
            let payload = try exactObject(
                try member("payload", in: current),
                required: [
                    "purpose", "scope_hash", "key_state_key", "key_state_hash", "artifact_key",
                    "artifact_hash", "artifact_payload_hash", "fencing_generation",
                    "config_version", "issued_at", "expires_at"
                ]
            )
            try requireStrings(
                [
                    "purpose", "scope_hash", "key_state_key", "key_state_hash", "artifact_key",
                    "artifact_hash", "artifact_payload_hash", "issued_at", "expires_at"
                ],
                in: payload
            )
            try requireNumbers(["fencing_generation", "config_version"], in: payload)
        case .accessDiscoveryPayload:
            let payload = try exactObject(
                value,
                required: accessDiscoveryPayloadRequiredKeys,
                optional: accessDiscoveryPayloadV2Keys
            )
            try requireStrings(
                [
                    "purpose", "tenant_id", "app_id", "platform", "environment",
                    "product_id", "channel", "client_identifier", "config_version",
                    "issued_at", "expires_at", "source", "content_hash"
                ],
                in: payload
            )
            try requireNumbers(
                [
                    "contract_version", "canonicalization_version", "fencing_generation", "generation",
                    "server_time", "ttl_seconds", "refresh_jitter_seconds"
                ],
                in: payload
            )
            try requireOptionalStrings(
                ["publication_id", "profile_fingerprint", "lifetime_mode", "status"],
                in: payload
            )
            try requireOptionalNumbers(["publication_revision", "keyset_revision"], in: payload)
            for listName in ["endpoints", "discovery_fallbacks"] {
                guard let endpoints = try member(listName, in: payload).arrayMembers else {
                    throw PreloginBootstrapError.invalidJSON
                }
                for endpoint in endpoints {
                    let members = try exactObject(
                        endpoint,
                        required: [
                            "id", "usage", "protocol", "url", "host", "port",
                            "priority", "weight", "network", "tls", "auth", "status",
                            "protected_resource_id", "protected_resource_type",
                            "protection_evidence_hash", "protection_expires_at"
                        ],
                        optional: [
                            "path", "resolved_ips", "tls_server_name", "http_host",
                            "dial_mode", "region", "provider", "connect_timeout_ms",
                            "heartbeat_seconds", "min_stable_seconds",
                            "failback_after_seconds", "cooldown_seconds", "max_parallel_race"
                        ]
                    )
                    try requireStrings(
                        [
                            "id", "usage", "protocol", "url", "host", "network",
                            "auth", "status", "protected_resource_id",
                            "protected_resource_type", "protection_evidence_hash",
                            "protection_expires_at"
                        ],
                        in: members
                    )
                    try requireOptionalStrings(
                        [
                            "path", "tls_server_name", "http_host", "dial_mode",
                            "region", "provider"
                        ],
                        in: members
                    )
                    try requireNumbers(["port", "priority", "weight"], in: members)
                    try requireOptionalNumbers(
                        [
                            "connect_timeout_ms", "heartbeat_seconds", "min_stable_seconds",
                            "failback_after_seconds", "cooldown_seconds", "max_parallel_race"
                        ],
                        in: members
                    )
                }
            }
        case .accessDiscoveryKeyStatePayload:
            let payload = try exactObject(
                value,
                required: [
                    "purpose", "contract_version", "recovery_generation",
                    "current_fencing_generation", "issued_at", "expires_at", "keys"
                ],
                optional: ["keyset_revision"]
            )
            try requireStrings(["purpose", "issued_at", "expires_at"], in: payload)
            try requireNumbers(
                ["contract_version", "recovery_generation", "current_fencing_generation"],
                in: payload
            )
            try requireOptionalNumbers(["keyset_revision"], in: payload)
            guard let keys = try member("keys", in: payload).arrayMembers else {
                throw PreloginBootstrapError.invalidJSON
            }
            for key in keys {
                let members = try exactObject(
                    key,
                    required: [
                        "key_id", "algorithm", "role", "status", "environment", "product_id",
                        "app_id", "platform", "channel", "client_identifier", "not_before",
                        "not_after", "min_fencing_generation"
                    ],
                    optional: ["max_fencing_generation"]
                )
                try requireStrings(
                    [
                        "key_id", "algorithm", "role", "status", "environment", "product_id",
                        "app_id", "platform", "channel", "client_identifier", "not_before",
                        "not_after"
                    ],
                    in: members
                )
                try requireNumbers(["min_fencing_generation"], in: members)
                try requireOptionalNumbers(["max_fencing_generation"], in: members)
            }
        }
    }

    private static let accessDiscoveryPayloadRequiredKeys: Set<String> = [
        "purpose", "contract_version", "canonicalization_version", "tenant_id",
        "app_id", "platform", "environment", "product_id", "channel",
        "client_identifier", "fencing_generation", "generation", "config_version", "issued_at",
        "expires_at", "server_time", "ttl_seconds", "refresh_jitter_seconds",
        "source", "stale", "degraded", "content_hash", "endpoints",
        "discovery_fallbacks"
    ]

    private static let accessDiscoveryPayloadV2Keys: Set<String> = [
        "publication_id", "publication_revision", "profile_fingerprint",
        "lifetime_mode", "status", "keyset_revision"
    ]

    private static func exactObject(
        _ value: PreloginJSONValue,
        required: Set<String>,
        optional: Set<String> = []
    ) throws -> [(String, PreloginJSONValue)] {
        guard let members = value.objectMembers else { throw PreloginBootstrapError.invalidJSON }
        let names = Set(members.map(\.0))
        guard required.isSubset(of: names), names.isSubset(of: required.union(optional)) else {
            throw PreloginBootstrapError.invalidJSON
        }
        return members
    }

    private static func member(
        _ name: String,
        in members: [(String, PreloginJSONValue)]
    ) throws -> PreloginJSONValue {
        guard let value = members.first(where: { $0.0 == name })?.1 else {
            throw PreloginBootstrapError.invalidJSON
        }
        return value
    }

    private static func requireStrings(
        _ names: Set<String>,
        in members: [(String, PreloginJSONValue)]
    ) throws {
        for name in names {
            guard case .string = try member(name, in: members) else {
                throw PreloginBootstrapError.invalidJSON
            }
        }
    }

    private static func requireOptionalStrings(
        _ names: Set<String>,
        in members: [(String, PreloginJSONValue)]
    ) throws {
        for name in names {
            guard let value = members.first(where: { $0.0 == name })?.1 else { continue }
            guard case .string = value else { throw PreloginBootstrapError.invalidJSON }
        }
    }

    private static func requireNumbers(
        _ names: Set<String>,
        in members: [(String, PreloginJSONValue)]
    ) throws {
        for name in names {
            guard case .number = try member(name, in: members) else {
                throw PreloginBootstrapError.invalidJSON
            }
        }
    }

    private static func requireOptionalNumbers(
        _ names: Set<String>,
        in members: [(String, PreloginJSONValue)]
    ) throws {
        for name in names {
            guard let value = members.first(where: { $0.0 == name })?.1 else { continue }
            guard case .number = value else { throw PreloginBootstrapError.invalidJSON }
        }
    }

    private static func render(_ value: PreloginJSONValue) throws -> Data {
        var output = Data()
        try append(value, to: &output)
        return output
    }

    private static func append(_ value: PreloginJSONValue, to output: inout Data) throws {
        switch value {
        case let .object(members):
            output.append(0x7B)
            let sorted = members.sorted {
                Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8))
            }
            for (offset, member) in sorted.enumerated() {
                if offset > 0 { output.append(0x2C) }
                appendJSONString(member.0, to: &output)
                output.append(0x3A)
                try append(member.1, to: &output)
            }
            output.append(0x7D)
        case let .array(values):
            output.append(0x5B)
            for (offset, item) in values.enumerated() {
                if offset > 0 { output.append(0x2C) }
                try append(item, to: &output)
            }
            output.append(0x5D)
        case let .string(string):
            appendJSONString(string, to: &output)
        case let .number(number):
            output.append(contentsOf: number.utf8)
        case let .boolean(value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .null:
            output.append(contentsOf: "null".utf8)
        }
    }

    // Matches encoding/json with escapeHTML enabled, which is the Go contract's
    // canonical string encoding.
    private static func appendJSONString(_ string: String, to output: inout Data) {
        output.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output.append(contentsOf: "\\\"".utf8)
            case 0x5C:
                output.append(contentsOf: "\\\\".utf8)
            case 0x08:
                output.append(contentsOf: "\\b".utf8)
            case 0x0C:
                output.append(contentsOf: "\\f".utf8)
            case 0x0A:
                output.append(contentsOf: "\\n".utf8)
            case 0x0D:
                output.append(contentsOf: "\\r".utf8)
            case 0x09:
                output.append(contentsOf: "\\t".utf8)
            case 0x00...0x1F, 0x3C, 0x3E, 0x26, 0x2028, 0x2029:
                let escaped = String(format: "\\u%04x", scalar.value)
                output.append(contentsOf: escaped.utf8)
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(0x22)
    }
}

// MARK: - Recovery authority, artifact and current-pointer verification

enum PreloginTrust {
    static let allowedClockSkew: TimeInterval = 300
    static let maxArtifactLifetime: TimeInterval = 24 * 3600
    static let maxKeyStateLifetime: TimeInterval = 7 * 24 * 3600
    static let maxSigningPayloadBytes = 4_096
    static let maxSignatureBytes = 512

    static func verifyKeyState(
        raw: Data,
        rootKeyID: String,
        rootPublicKey: Data,
        previousRecoveryGeneration: UInt64,
        previousHash: String,
        now: Date
    ) throws -> PreloginVerifiedKeyState {
        let state = try PreloginStrictJSON.decodeKeyState(raw)
        guard !rootKeyID.isEmpty, state.rootKeyID == rootKeyID else {
            throw PreloginBootstrapError.untrustedRecoveryRoot
        }
        let payload = state.payload
        guard payload.purpose == "prelogin_key_state",
              payload.contractVersion == 1,
              payload.recoveryGeneration > 0,
              payload.currentFencingGeneration > 0,
              !payload.keys.isEmpty,
              payload.keys.count <= 64 else {
            throw PreloginBootstrapError.invalidContract
        }
        try validateTime(
            payload.issuedAt,
            payload.expiresAt,
            maxLifetime: maxKeyStateLifetime,
            now: now
        )
        var authorizations: [String: PreloginKeyAuthorization] = [:]
        for key in payload.keys {
            try validateAuthorization(key)
            guard authorizations.updateValue(key, forKey: key.keyID) == nil else {
                throw PreloginBootstrapError.invalidContract
            }
        }
        let signing = try PreloginStrictJSON.canonical(payload)
        try validateSigningPayloadSize(signing)
        try verify(
            signature: state.signature,
            algorithm: state.signatureAlg,
            message: signing,
            publicKey: rootPublicKey
        )
        let hash = sha256(signing)
        guard payload.recoveryGeneration >= previousRecoveryGeneration else {
            throw PreloginBootstrapError.recoveryRollback
        }
        if payload.recoveryGeneration == previousRecoveryGeneration,
           !previousHash.isEmpty,
           previousHash != hash {
            throw PreloginBootstrapError.recoveryConflict
        }
        return PreloginVerifiedKeyState(
            raw: raw,
            state: state,
            canonicalPayload: signing,
            payloadHash: hash,
            objectHash: sha256(raw),
            authorizations: authorizations
        )
    }

    static func arbitrateKeyStates(
        _ candidates: [(sourceID: String, state: PreloginVerifiedKeyState)]
    ) throws -> PreloginVerifiedKeyState {
        guard !candidates.isEmpty else { throw PreloginBootstrapError.noValidCandidate }
        let sorted = candidates.sorted {
            $0.state.state.payload.recoveryGeneration > $1.state.state.payload.recoveryGeneration
        }
        let selected = sorted[0].state
        for candidate in sorted
        where candidate.state.state.payload.recoveryGeneration == selected.state.payload.recoveryGeneration {
            guard candidate.state.payloadHash == selected.payloadHash else {
                throw PreloginBootstrapError.recoveryConflict
            }
        }
        return selected
    }

    static func verifyArtifact(
        raw: Data,
        scope: PreloginExpectedScope,
        keyState: PreloginVerifiedKeyState,
        publicKeys: [String: Data],
        now: Date
    ) throws -> PreloginVerifiedArtifact {
        let artifact = try PreloginStrictJSON.decodeArtifact(raw)
        let payload = artifact.payload
        guard payload.purpose == "prelogin_bootstrap",
              payload.contractVersion == 1,
              payload.canonicalizationVersion == 1 else {
            throw PreloginBootstrapError.invalidContract
        }
        guard payload.environment == scope.environment, payload.audience == scope.audience else {
            throw PreloginBootstrapError.scopeMismatch
        }
        guard ["production", "staging", "test"].contains(payload.environment),
              payload.audience.platform == "ios",
              boundedToken(payload.audience.productID, maximum: 128),
              boundedToken(payload.audience.appID, maximum: 128),
              boundedToken(payload.audience.bundleID ?? "", maximum: 255),
              payload.audience.packageName == nil,
              boundedToken(payload.audience.channel, maximum: 64),
              boundedToken(payload.keyID, maximum: 128),
              payload.fencingGeneration > 0,
              payload.configVersion > 0,
              !payload.endpoints.isEmpty,
              payload.endpoints.count <= 32,
              isLowercaseSHA256(payload.contentHash) else {
            throw PreloginBootstrapError.invalidContract
        }
        try validateTime(
            payload.issuedAt,
            payload.expiresAt,
            maxLifetime: maxArtifactLifetime,
            now: now
        )
        try validateEndpoints(payload.endpoints)
        let endpointBytes = try PreloginStrictJSON.canonical(payload.endpoints)
        guard sha256(endpointBytes) == payload.contentHash else {
            throw PreloginBootstrapError.contentHashMismatch
        }
        guard keyState.state.payload.currentFencingGeneration == payload.fencingGeneration,
              let authorization = keyState.authorizations[payload.keyID],
              authorization.status == "active",
              authorization.algorithm == artifact.signatureAlg,
              authorizationScope(authorization) == scope,
              payload.fencingGeneration >= authorization.minFencingGeneration,
              authorization.maxFencingGeneration.map({ payload.fencingGeneration <= $0 }) ?? true,
              let publicKey = publicKeys[payload.keyID] else {
            throw PreloginBootstrapError.keyUnauthorized
        }
        let signing = try PreloginStrictJSON.canonical(payload)
        try validateSigningPayloadSize(signing)
        try verify(
            signature: artifact.signature,
            algorithm: artifact.signatureAlg,
            message: signing,
            publicKey: publicKey
        )
        return PreloginVerifiedArtifact(
            raw: raw,
            artifact: artifact,
            canonicalPayload: signing,
            payloadHash: sha256(signing)
        )
    }

    static func verifyCurrent(
        raw: Data,
        scope: PreloginExpectedScope,
        keyState: PreloginVerifiedKeyState,
        publicKeys: [String: Data],
        now: Date
    ) throws -> PreloginVerifiedCurrent {
        let pointer = try PreloginStrictJSON.decodeCurrent(raw)
        let payload = pointer.payload
        let expectedKeyStateKey = [
            "bootstrap-v1",
            payload.scopeHash,
            "key-states",
            "\(payload.keyStateHash).json"
        ].joined(separator: "/")
        guard payload.purpose == "prelogin_bootstrap_current",
              payload.scopeHash == scopeHash(scope),
              payload.keyStateKey == expectedKeyStateKey,
              payload.keyStateHash == keyState.objectHash,
              isSafeArtifactKey(payload.keyStateKey),
              isSafeArtifactKey(payload.artifactKey),
              isLowercaseSHA256(payload.artifactHash),
              isLowercaseSHA256(payload.artifactPayloadHash),
              payload.fencingGeneration > 0,
              payload.configVersion > 0 else {
            throw PreloginBootstrapError.currentPointerInvalid
        }
        let expectedArtifactKey = [
            "bootstrap-v1",
            payload.scopeHash,
            "fence-\(payload.fencingGeneration)",
            "version-\(payload.configVersion)-\(payload.artifactHash).json"
        ].joined(separator: "/")
        guard payload.artifactKey == expectedArtifactKey else {
            throw PreloginBootstrapError.currentPointerInvalid
        }
        guard let authorization = keyState.authorizations[pointer.keyID],
              authorization.status == "active",
              authorization.algorithm == pointer.signatureAlg,
              authorizationScope(authorization) == scope,
              payload.fencingGeneration == keyState.state.payload.currentFencingGeneration,
              payload.fencingGeneration >= authorization.minFencingGeneration,
              authorization.maxFencingGeneration.map({ payload.fencingGeneration <= $0 }) ?? true,
              let publicKey = publicKeys[pointer.keyID] else {
            throw PreloginBootstrapError.keyUnauthorized
        }
        try validateTime(
            payload.issuedAt,
            payload.expiresAt,
            maxLifetime: maxArtifactLifetime,
            now: now
        )
        let signing = try PreloginStrictJSON.canonical(payload)
        try validateSigningPayloadSize(signing)
        try verify(
            signature: pointer.signature,
            algorithm: pointer.signatureAlg,
            message: signing,
            publicKey: publicKey
        )
        return PreloginVerifiedCurrent(raw: raw, pointer: pointer)
    }

    static func keyStateReference(
        currentRaw: Data,
        scope: PreloginExpectedScope
    ) throws -> (key: String, hash: String) {
        let pointer = try PreloginStrictJSON.decodeCurrent(currentRaw)
        let payload = pointer.payload
        let expectedScopeHash = scopeHash(scope)
        let expectedKey = [
            "bootstrap-v1",
            expectedScopeHash,
            "key-states",
            "\(payload.keyStateHash).json"
        ].joined(separator: "/")
        guard payload.purpose == "prelogin_bootstrap_current",
              payload.scopeHash == expectedScopeHash,
              isLowercaseSHA256(payload.keyStateHash),
              payload.keyStateKey == expectedKey,
              isSafeArtifactKey(payload.keyStateKey) else {
            throw PreloginBootstrapError.currentPointerInvalid
        }
        return (payload.keyStateKey, payload.keyStateHash)
    }

    static func verifyPointerArtifactBinding(
        pointer: PreloginVerifiedCurrent,
        artifact: PreloginVerifiedArtifact
    ) throws {
        let pointerPayload = pointer.pointer.payload
        let artifactPayload = artifact.artifact.payload
        guard pointer.pointer.keyID == artifactPayload.keyID,
              pointerPayload.artifactHash == sha256(artifact.raw),
              pointerPayload.artifactPayloadHash == artifact.payloadHash,
              pointerPayload.fencingGeneration == artifactPayload.fencingGeneration,
              pointerPayload.configVersion == artifactPayload.configVersion,
              pointerPayload.issuedAt == artifactPayload.issuedAt,
              pointerPayload.expiresAt == artifactPayload.expiresAt else {
            throw PreloginBootstrapError.currentPointerInvalid
        }
    }

    static func arbitrate(
        _ candidates: [(sourceID: String, artifact: PreloginVerifiedArtifact)]
    ) throws -> PreloginVerifiedArtifact {
        guard !candidates.isEmpty else { throw PreloginBootstrapError.noValidCandidate }
        let sorted = candidates.sorted {
            let lhs = $0.artifact.artifact.payload
            let rhs = $1.artifact.artifact.payload
            return lhs.fencingGeneration == rhs.fencingGeneration
                ? lhs.configVersion > rhs.configVersion
                : lhs.fencingGeneration > rhs.fencingGeneration
        }
        let selected = sorted[0].artifact
        for candidate in sorted
        where candidate.artifact.artifact.payload.fencingGeneration
            == selected.artifact.payload.fencingGeneration
            && candidate.artifact.artifact.payload.configVersion
            == selected.artifact.payload.configVersion {
            guard candidate.artifact.payloadHash == selected.payloadHash,
                  candidate.artifact.artifact.payload.contentHash
                    == selected.artifact.payload.contentHash else {
                throw PreloginBootstrapError.candidateConflict
            }
        }
        return selected
    }

    static func platformBase(from artifact: PreloginVerifiedArtifact) throws -> URL {
        let candidates = artifact.artifact.payload.endpoints
            .filter { $0.usage == "platform_api" && $0.protocol == "https" }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.id < $1.id
            }
        guard let raw = candidates.first?.url, let url = URL(string: raw) else {
            throw PreloginBootstrapError.invalidContract
        }
        return url
    }

    static func scopeHash(_ scope: PreloginExpectedScope) -> String {
        let contract = PreloginScopeHashContract(
            environment: scope.environment,
            productID: scope.productID,
            appID: scope.appID,
            bundleID: scope.bundleID,
            packageName: nil,
            channel: scope.channel,
            platform: scope.platform
        )
        guard let canonical = try? PreloginStrictJSON.canonical(contract) else { return "" }
        return sha256(canonical)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateAuthorization(_ key: PreloginKeyAuthorization) throws {
        guard boundedToken(key.keyID, maximum: 128),
              key.algorithm == "Ed25519",
              ["active", "revoked"].contains(key.status),
              ["production", "staging", "test"].contains(key.environment),
              key.platform == "ios",
              boundedToken(key.productID, maximum: 128),
              boundedToken(key.appID, maximum: 128),
              boundedToken(key.bundleID ?? "", maximum: 255),
              key.packageName == nil,
              boundedToken(key.channel, maximum: 64),
              key.minFencingGeneration > 0,
              key.maxFencingGeneration.map({ $0 >= key.minFencingGeneration }) ?? true else {
            throw PreloginBootstrapError.invalidContract
        }
    }

    private static func authorizationScope(
        _ authorization: PreloginKeyAuthorization
    ) -> PreloginExpectedScope {
        PreloginExpectedScope(
            environment: authorization.environment,
            productID: authorization.productID,
            appID: authorization.appID,
            bundleID: authorization.bundleID ?? "",
            channel: authorization.channel,
            platform: authorization.platform
        )
    }

    private static func validateEndpoints(_ endpoints: [PreloginEndpoint]) throws {
        var ids = Set<String>()
        for endpoint in endpoints {
            guard ids.insert(endpoint.id).inserted,
                  boundedToken(endpoint.id, maximum: 128),
                  ["platform_api", "platform_web", "discovery"].contains(endpoint.usage),
                  ["https", "wss", "tcp_tls"].contains(endpoint.protocol),
                  endpoint.priority >= 0,
                  endpoint.priority <= 10_000,
                  endpoint.port > 0,
                  endpoint.port <= 65_535,
                  !endpoint.path.isEmpty,
                  endpoint.path.hasPrefix("/"),
                  !endpoint.path.contains(".."),
                  endpoint.path.rangeOfCharacter(from: CharacterSet(charactersIn: "?#\\")) == nil,
                  endpoint.url.utf8.count <= 2_048,
                  endpoint.host == endpoint.host.lowercased(),
                  validHostname(endpoint.host),
                  !isIPAddress(endpoint.host),
                  let components = URLComponents(string: endpoint.url),
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.host?.lowercased() == endpoint.host,
                  components.percentEncodedPath == endpoint.path,
                  components.scheme == expectedScheme(endpoint.protocol) else {
                throw PreloginBootstrapError.invalidContract
            }
            let effectivePort = components.port ?? 443
            guard effectivePort == endpoint.port,
                  components.port != nil || endpoint.port == 443 else {
                throw PreloginBootstrapError.invalidContract
            }
        }
    }

    private static func expectedScheme(_ protocolValue: String) -> String? {
        switch protocolValue {
        case "https": "https"
        case "wss": "wss"
        case "tcp_tls": "tcp+tls"
        default: nil
        }
    }

    private static func validHostname(_ hostname: String) -> Bool {
        guard !hostname.isEmpty,
              hostname.utf8.count <= 253,
              !hostname.hasPrefix("."),
              !hostname.hasSuffix(".") else { return false }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-" else { return false }
            return label.allSatisfy {
                ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
            }
        }
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return String(value) == part
        }
    }

    private static func validateTime(
        _ issuedRaw: String,
        _ expiresRaw: String,
        maxLifetime: TimeInterval,
        now: Date
    ) throws {
        guard let issued = parseRFC3339(issuedRaw),
              let expires = parseRFC3339(expiresRaw),
              expires > issued else {
            throw PreloginBootstrapError.invalidContract
        }
        guard expires.timeIntervalSince(issued) <= maxLifetime else {
            throw PreloginBootstrapError.lifetimeTooLong
        }
        guard issued <= now.addingTimeInterval(allowedClockSkew) else {
            throw PreloginBootstrapError.notYetValid
        }
        guard expires > now.addingTimeInterval(-allowedClockSkew) else {
            throw PreloginBootstrapError.expired
        }
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 20,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes[19] == 90,
              bytes.enumerated().allSatisfy({ index, byte in
                  [4, 7, 10, 13, 16, 19].contains(index)
                      || byte >= 48 && byte <= 57
              }) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let parsed = formatter.date(from: value),
              formatter.string(from: parsed) == value else {
            return nil
        }
        return parsed
    }

    private static func verify(
        signature: String,
        algorithm: String,
        message: Data,
        publicKey: Data
    ) throws {
        guard algorithm == "Ed25519",
              signature.utf8.count <= (4 * maxSignatureBytes / 3) + 8,
              let signatureData = Data(base64Encoded: signature, options: []),
              signatureData.count == 64,
              signatureData.base64EncodedString() == signature,
              publicKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signatureData, for: message) else {
            throw PreloginBootstrapError.signatureInvalid
        }
    }

    private static func validateSigningPayloadSize(_ signing: Data) throws {
        guard signing.count <= maxSigningPayloadBytes else {
            throw PreloginBootstrapError.signingPayloadTooLarge
        }
    }

    private static func boundedToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\t")) == nil
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.allSatisfy {
                ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
            }
    }

    private static func isSafeArtifactKey(_ key: String) -> Bool {
        guard key.hasPrefix("bootstrap-v1/"),
              !key.hasPrefix("/"),
              key.utf8.count <= 2_048,
              !key.contains("\\"),
              !key.contains("?"),
              !key.contains("#"),
              !key.contains("%"),
              key.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "/-._".contains($0))
              }) else {
            return false
        }
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

import CryptoKit
import Foundation

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

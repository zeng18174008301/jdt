import CryptoKit
import Foundation

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

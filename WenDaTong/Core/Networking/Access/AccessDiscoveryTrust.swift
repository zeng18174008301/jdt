import CryptoKit
import Foundation
import Network

enum AccessDiscoveryTrustError: String, Error {
    case configurationBlocked = "access_discovery_trust_configuration_blocked"
    case invalidEnvelope = "access_discovery_signature_invalid_envelope"
    case unknownKey = "access_discovery_signature_unknown_key"
    case signatureInvalid = "access_discovery_signature_invalid"
    case audienceMismatch = "access_discovery_signature_audience_mismatch"
    case expired = "access_discovery_signature_expired"
    case endpointInvalid = "access_discovery_signed_endpoint_invalid"
    case rollback = "access_discovery_signature_rollback"
    case conflict = "access_discovery_signature_conflict"
}

struct AccessDiscoveryTrustConfiguration: Sendable {
    static let signingDomain = Data("wenxintong.tenant-access-discovery.v1\u{0}".utf8)
    static let keyStateSigningDomain = Data("wenxintong.tenant-access-discovery-key-state.v1\u{0}".utf8)
    let required: Bool
    let environment: String
    let productID: String
    let appID: String
    let channel: String
    let clientIdentifier: String
    let publicKeys: [String: Data]
    let recoveryRootKeyID: String
    let recoveryRootPublicKey: Data

    init(
        required: Bool,
        environment: String,
        productID: String,
        appID: String,
        channel: String,
        clientIdentifier: String,
        publicKeys: [String: Data],
        recoveryRootKeyID: String = "",
        recoveryRootPublicKey: Data = Data()
    ) {
        self.required = required
        self.environment = environment
        self.productID = productID
        self.appID = appID
        self.channel = channel
        self.clientIdentifier = clientIdentifier
        self.publicKeys = publicKeys
        self.recoveryRootKeyID = recoveryRootKeyID
        self.recoveryRootPublicKey = recoveryRootPublicKey
    }

    static func load(bundle: Bundle = .main) -> AccessDiscoveryTrustConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let requiredValue = info["WXTAccessDiscoverySigningRequired"]
        let required = (requiredValue as? Bool) == true ||
            ["1", "true", "yes", "on"].contains((requiredValue as? String ?? "").lowercased())
        var configuredKeys = info["WXTAccessDiscoveryPublicKeys"] as? [String: String] ?? [:]
        if configuredKeys.isEmpty,
           let raw = (info["WXTAccessDiscoveryPublicKeysJSON"] as? String)?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: raw) {
            configuredKeys = decoded
        }
        let keys = configuredKeys.reduce(into: [String: Data]()) {
            if let decoded = Data(base64Encoded: $1.value), decoded.count == 32 {
                $0[$1.key] = decoded
            }
        }
        return AccessDiscoveryTrustConfiguration(
            required: required,
            environment: (info["WXTAccessDiscoveryEnvironment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            productID: (info["WXTAccessDiscoveryProductID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            appID: (info["WXTAccessDiscoveryAppID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            channel: (info["WXTAccessDiscoveryChannel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            clientIdentifier: bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            publicKeys: keys,
            recoveryRootKeyID: (info["WXTAccessDiscoveryRecoveryRootKeyID"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            recoveryRootPublicKey: Data(
                base64Encoded: (info["WXTAccessDiscoveryRecoveryRootPublicKeyB64"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? Data()
        )
    }

    func verify(
        _ envelope: SignedAccessDiscoveryEnvelope,
        context: IMAPIContext,
        now: Date = Date()
    ) throws -> RemoteAccessDiscoveryResponse {
        try verifyEnvelope(envelope, context: context, now: now, persistedLastGood: false)
    }

    private func verifyEnvelope(
        _ envelope: SignedAccessDiscoveryEnvelope,
        context: IMAPIContext,
        now: Date,
        persistedLastGood: Bool
    ) throws -> RemoteAccessDiscoveryResponse {
        guard required,
              !environment.isEmpty, !productID.isEmpty, !appID.isEmpty, !channel.isEmpty,
              !clientIdentifier.isEmpty, !publicKeys.isEmpty,
              !recoveryRootKeyID.isEmpty, recoveryRootPublicKey.count == 32 else {
            throw AccessDiscoveryTrustError.configurationBlocked
        }
        guard envelope.signatureAlg == "Ed25519",
              let canonicalPayload = Data(base64Encoded: envelope.payloadB64),
              canonicalPayload.count <= 64 * 1024,
              let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64 else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let payload = try PreloginStrictJSON.decodeAccessDiscoveryPayload(canonicalPayload)
        let tenantID = context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appID = IMAPIContext.normalizedIOSAppID(context.appID)
        let isV2 = payload.contractVersion == 2
        let normalizedStatus = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedFingerprint = payload.profileFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
        let v2MetadataIsValid = !isV2 || (
            payload.publicationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && (payload.publicationRevision ?? 0) > 0
                && normalizedFingerprint == payload.contentHash
                && payload.lifetimeMode == .untilRevoked
                && ["active", "disabled", "tombstone"].contains(normalizedStatus ?? "")
                && (payload.keysetRevision ?? 0) > 0
        )
        let v1MetadataIsExact = isV2 || (
            payload.contractVersion == 1
                && payload.publicationID == nil
                && payload.publicationRevision == nil
                && payload.profileFingerprint == nil
                && payload.lifetimeMode == nil
                && payload.status == nil
                && payload.keysetRevision == nil
        )
        guard payload.purpose == "tenant_access_discovery",
              [1, 2].contains(payload.contractVersion),
              payload.canonicalizationVersion == 1,
              v2MetadataIsValid,
              v1MetadataIsExact,
              payload.tenantID == tenantID,
              appID == self.appID,
              payload.appID == self.appID,
              payload.platform == "ios",
              payload.environment == environment,
              payload.productID == productID,
              payload.channel == channel,
              payload.clientIdentifier == clientIdentifier else {
            throw AccessDiscoveryTrustError.audienceMismatch
        }
        let verifiedKeyState = try verifyKeyState(
            envelope.keyState,
            payload: payload,
            signingKeyID: envelope.keyID,
            now: now,
            allowsHistoricalAuthorization: persistedLastGood && isV2
        )
        if isV2, verifiedKeyState.payload.keysetRevision != payload.keysetRevision {
            throw AccessDiscoveryTrustError.conflict
        }
        guard let publicKeyData = publicKeys[envelope.keyID],
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw AccessDiscoveryTrustError.unknownKey
        }
        var domainMessage = Self.signingDomain
        domainMessage.append(canonicalPayload)
        let signingDigest = Data(SHA512.hash(data: domainMessage))
        guard publicKey.isValidSignature(signature, for: signingDigest) else {
            throw AccessDiscoveryTrustError.signatureInvalid
        }
        let formatter = ISO8601DateFormatter()
        guard let issuedAt = formatter.date(from: payload.issuedAt),
              let expiresAt = formatter.date(from: payload.expiresAt),
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 3_600,
              (persistedLastGood && isV2 || (
                issuedAt <= now.addingTimeInterval(300) && expiresAt > now
              )) else {
            throw AccessDiscoveryTrustError.expired
        }
        guard payload.generation > 0,
              !payload.configVersion.isEmpty,
              payload.contentHash == (try PreloginStrictJSON.accessDiscoveryExecutableHash(canonicalPayload)),
              (normalizedStatus != "active" || payload.endpoints.contains(where: {
                $0.normalizedStatus == "ready" && $0.isRealtimeWebSocketCandidate
              })) else {
            throw AccessDiscoveryTrustError.endpointInvalid
        }
        if payload.environment == "production" {
            guard Self.productionDomainOnlyPayloadIsExact(canonicalPayload, payload: payload),
                  Self.productionDomainOnlyPoolIsValid(payload.endpoints + payload.discoveryFallbacks) else {
                throw AccessDiscoveryTrustError.endpointInvalid
            }
        }
        let endpointValidationTime = persistedLastGood && isV2 ? issuedAt : now
        for endpoint in payload.endpoints + payload.discoveryFallbacks {
            guard endpoint.isSignedProtectedEndpointValid(at: endpointValidationTime, validUntil: expiresAt) else {
                throw AccessDiscoveryTrustError.endpointInvalid
            }
        }
        return RemoteAccessDiscoveryResponse(
            contractVersion: payload.contractVersion,
            configVersion: payload.configVersion,
            serverTime: payload.serverTime,
            ttlSeconds: payload.ttlSeconds,
            refreshJitterSeconds: payload.refreshJitterSeconds,
            source: payload.source,
            stale: payload.stale,
            degraded: payload.degraded,
            endpoints: payload.endpoints,
            discoveryFallbacks: payload.discoveryFallbacks,
            signatureAlg: envelope.signatureAlg,
            signature: envelope.signature,
            trust: AccessDiscoveryTrustProof(
                payloadB64: envelope.payloadB64, keyID: envelope.keyID,
                signatureAlg: envelope.signatureAlg, signature: envelope.signature,
                keyState: envelope.keyState,
                generation: payload.generation,
                fencingGeneration: payload.fencingGeneration,
                recoveryGeneration: verifiedKeyState.payload.recoveryGeneration,
                keyStateHash: verifiedKeyState.payloadHash,
                keyStateExpiresAt: verifiedKeyState.payload.expiresAt,
                contentHash: payload.contentHash,
                issuedAt: payload.issuedAt, expiresAt: payload.expiresAt,
                environment: payload.environment, productID: payload.productID,
                appID: payload.appID, channel: payload.channel,
                clientIdentifier: payload.clientIdentifier,
                tenantID: payload.tenantID, platform: payload.platform,
                publicationID: payload.publicationID,
                publicationRevision: payload.publicationRevision,
                profileFingerprint: payload.profileFingerprint,
                lifetimeMode: payload.lifetimeMode,
                publicationStatus: normalizedStatus,
                keysetRevision: payload.keysetRevision
            ),
            publicationID: payload.publicationID,
            publicationRevision: payload.publicationRevision,
            profileFingerprint: payload.profileFingerprint,
            lifetimeMode: payload.lifetimeMode,
            publicationStatus: normalizedStatus,
            keysetRevision: payload.keysetRevision
        )
    }

    static func productionDomainOnlyPoolIsValid(_ endpoints: [RemoteAccessDiscoveryEndpoint]) -> Bool {
        var ids = Set<String>()
        var candidates = Set<String>()
        for endpoint in endpoints {
            guard endpoint.isProductionDomainOnlyEndpoint,
                  ids.insert(endpoint.id).inserted,
                  let identity = endpoint.productionCandidateIdentity,
                  candidates.insert(identity).inserted else {
                return false
            }
        }
        return true
    }

    private static func productionDomainOnlyPayloadIsExact(
        _ canonicalPayload: Data,
        payload: SignedAccessDiscoveryPayload
    ) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: canonicalPayload) as? [String: Any] else {
            return false
        }
        let collections: [(String, [RemoteAccessDiscoveryEndpoint])] = [
            ("endpoints", payload.endpoints),
            ("discovery_fallbacks", payload.discoveryFallbacks)
        ]
        for (name, decoded) in collections {
            guard let raw = document[name] as? [[String: Any]], raw.count == decoded.count else {
                return false
            }
            for endpoint in raw {
                guard let resolved = endpoint["resolved_ips"] as? [Any], resolved.isEmpty,
                      endpoint["dial_mode"] as? String == "domain_only" else {
                    return false
                }
            }
        }
        return true
    }

    private func verifyKeyState(
        _ state: SignedAccessDiscoveryKeyState,
        payload: SignedAccessDiscoveryPayload,
        signingKeyID: String,
        now: Date,
        allowsHistoricalAuthorization: Bool
    ) throws -> (payload: AccessDiscoveryKeyStatePayload, payloadHash: String) {
        guard state.rootKeyID == recoveryRootKeyID,
              state.signatureAlg == "Ed25519",
              let canonicalPayload = Data(base64Encoded: state.payloadB64),
              canonicalPayload.count <= 64 * 1024,
              let signature = Data(base64Encoded: state.signature),
              signature.count == 64,
              let rootPublicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: recoveryRootPublicKey) else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        let keyState = try PreloginStrictJSON.decodeAccessDiscoveryKeyStatePayload(canonicalPayload)
        let formatter = ISO8601DateFormatter()
        guard keyState.purpose == "tenant_access_discovery_key_state",
              keyState.contractVersion == payload.contractVersion,
              (keyState.contractVersion == 1
                ? keyState.keysetRevision == nil
                : (keyState.keysetRevision ?? 0) > 0),
              keyState.recoveryGeneration > 0,
              keyState.currentFencingGeneration > 0,
              !keyState.keys.isEmpty,
              keyState.keys.count <= 64,
              let issuedAt = formatter.date(from: keyState.issuedAt),
              let expiresAt = formatter.date(from: keyState.expiresAt),
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 8 * 24 * 3_600,
              (allowsHistoricalAuthorization || (
                issuedAt <= now.addingTimeInterval(300) && expiresAt > now
              )) else {
            throw AccessDiscoveryTrustError.expired
        }
        var domainMessage = Self.keyStateSigningDomain
        domainMessage.append(canonicalPayload)
        let digest = Data(SHA512.hash(data: domainMessage))
        guard rootPublicKey.isValidSignature(signature, for: digest) else {
            throw AccessDiscoveryTrustError.signatureInvalid
        }
        var seen = Set<String>()
        var activeAtCurrentFence: [String: Int] = [:]
        var authorized = false
        for key in keyState.keys {
            let scope = [
                key.keyID, key.environment, key.productID, key.appID,
                key.platform, key.channel, key.clientIdentifier
            ].joined(separator: "\u{0}")
            guard seen.insert(scope).inserted,
                  key.algorithm == "Ed25519",
                  ["primary", "standby"].contains(key.role),
                  (keyState.contractVersion == 1
                    ? ["active", "revoked"].contains(key.status)
                    : ["active", "retired", "revoked"].contains(key.status)),
                  key.minFencingGeneration > 0,
                  key.maxFencingGeneration.map({ $0 >= key.minFencingGeneration }) ?? true,
                  let notBefore = formatter.date(from: key.notBefore),
                  let notAfter = formatter.date(from: key.notAfter),
                  notAfter > notBefore,
                  notAfter > issuedAt else {
                throw AccessDiscoveryTrustError.invalidEnvelope
            }
            if key.role == "standby", key.status == "active" {
                guard key.minFencingGeneration >= keyState.currentFencingGeneration else {
                    throw AccessDiscoveryTrustError.invalidEnvelope
                }
                if key.minFencingGeneration == keyState.currentFencingGeneration {
                    guard keyState.recoveryGeneration > 1,
                          key.maxFencingGeneration == keyState.currentFencingGeneration else {
                        throw AccessDiscoveryTrustError.invalidEnvelope
                    }
                }
            }
            if key.status == "active",
               keyState.currentFencingGeneration >= key.minFencingGeneration,
               key.maxFencingGeneration.map({ keyState.currentFencingGeneration <= $0 }) ?? true {
                let audience = [
                    key.environment, key.productID, key.appID, key.platform,
                    key.channel, key.clientIdentifier
                ].joined(separator: "\u{0}")
                activeAtCurrentFence[audience, default: 0] += 1
                guard activeAtCurrentFence[audience] == 1 else {
                    throw AccessDiscoveryTrustError.invalidEnvelope
                }
            }
            if key.keyID == signingKeyID,
               (key.status == "active" || (allowsHistoricalAuthorization && key.status == "retired")),
               key.environment == environment,
               key.productID == productID,
               key.appID == appID,
               key.platform == "ios",
               key.channel == channel,
               key.clientIdentifier == clientIdentifier,
               payload.fencingGeneration == keyState.currentFencingGeneration,
               payload.fencingGeneration >= key.minFencingGeneration,
               key.maxFencingGeneration.map({ payload.fencingGeneration <= $0 }) ?? true,
               key.role != "standby" || (
                keyState.recoveryGeneration > 1 &&
                    key.minFencingGeneration == keyState.currentFencingGeneration &&
                    key.maxFencingGeneration == keyState.currentFencingGeneration
               ),
               (allowsHistoricalAuthorization || (
                now >= notBefore.addingTimeInterval(-300) && now < notAfter
               )) {
                authorized = true
            }
        }
        guard authorized else { throw AccessDiscoveryTrustError.unknownKey }
        return (keyState, PreloginTrust.sha256(canonicalPayload))
    }

    func verifyStored(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext,
        now: Date = Date()
    ) throws -> RemoteAccessDiscoveryResponse {
        guard let proof = response.trust else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        return try verifyEnvelope(
            SignedAccessDiscoveryEnvelope(
                payloadB64: proof.payloadB64,
                keyID: proof.keyID,
                signatureAlg: proof.signatureAlg,
                signature: proof.signature,
                keyState: proof.keyState
            ),
            context: context,
            now: now,
            persistedLastGood: true
        )
    }

    func verifyNetworkResponse(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext,
        now: Date = Date()
    ) throws -> RemoteAccessDiscoveryResponse {
        guard let proof = response.trust else {
            throw AccessDiscoveryTrustError.invalidEnvelope
        }
        return try verifyEnvelope(
            SignedAccessDiscoveryEnvelope(
                payloadB64: proof.payloadB64,
                keyID: proof.keyID,
                signatureAlg: proof.signatureAlg,
                signature: proof.signature,
                keyState: proof.keyState
            ),
            context: context,
            now: now,
            persistedLastGood: false
        )
    }
}

private extension SignedAccessDiscoveryEnvelope {
    init(
        payloadB64: String,
        keyID: String,
        signatureAlg: String,
        signature: String,
        keyState: SignedAccessDiscoveryKeyState
    ) {
        self.payloadB64 = payloadB64
        self.keyID = keyID
        self.signatureAlg = signatureAlg
        self.signature = signature
        self.keyState = keyState
    }
}

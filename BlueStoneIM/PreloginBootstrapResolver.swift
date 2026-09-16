import Foundation
import Security

struct PreloginSeed: Sendable, Equatable {
    let id: String
    let baseURL: URL
}

struct PreloginBootstrapConfiguration: Sendable {
    let seeds: [PreloginSeed]
    let scope: PreloginExpectedScope
    let rootKeyID: String
    let rootPublicKey: Data
    let artifactPublicKeys: [String: Data]

    func validate() throws {
        guard seeds.count == 3,
              Set(seeds.map(\.id)).count == 3,
              Set(seeds.compactMap { $0.baseURL.host?.lowercased() }).count == 3,
              !rootKeyID.isEmpty,
              rootPublicKey.count == 32,
              !artifactPublicKeys.isEmpty,
              artifactPublicKeys.values.allSatisfy({ $0.count == 32 }) else {
            throw PreloginBootstrapError.configurationBlocked
        }
        for seed in seeds {
            guard !seed.id.isEmpty,
                  seed.id.utf8.count <= 128,
                  seed.id.trimmingCharacters(in: .whitespacesAndNewlines) == seed.id,
                  seed.id.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\t")) == nil,
                  seed.baseURL.scheme == "https",
                  seed.baseURL.user == nil,
                  seed.baseURL.password == nil,
                  seed.baseURL.query == nil,
                  seed.baseURL.fragment == nil,
                  seed.baseURL.port == nil || seed.baseURL.port == 443,
                  let host = seed.baseURL.host?.lowercased(),
                  host.contains("."),
                  !seed.baseURL.path.contains(".."),
                  !seed.baseURL.path.contains("%"),
                  !seed.baseURL.path.contains("\\"),
                  !Self.isIPAddress(host) else {
                throw PreloginBootstrapError.configurationBlocked
            }
        }
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }
}

struct PreloginLastGoodEnvelope: Codable, Sendable {
    let scopeHash: String
    let artifact: Data
    let keyState: Data
    let currentPointer: Data
    let savedAt: Date
}

struct PreloginTrustCheckpoint: Codable, Equatable, Sendable {
    let scopeHash: String
    let recoveryGeneration: UInt64
    let recoveryHash: String
    let fencingGeneration: UInt64
    let configVersion: UInt64
    let payloadHash: String
    let lastTrustedWallClock: Date
    let lastNetworkSavedAt: Date
}

protocol PreloginLastGoodStoring: Sendable {
    func loadEnvelope() async throws -> PreloginLastGoodEnvelope?
    func loadCheckpoint() async throws -> PreloginTrustCheckpoint?
    func saveEnvelope(_ value: PreloginLastGoodEnvelope) async throws
    func saveCheckpoint(_ value: PreloginTrustCheckpoint) async throws
}

actor PreloginSecureLastGoodStore: PreloginLastGoodStoring {
    private let fileURL: URL
    private let keychainService: String
    private let keychainAccount: String

    init(
        scopeHash: String,
        fileURL: URL? = nil,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.wenxintong.unconfigured"
    ) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL
            ?? support.appendingPathComponent(
                "BlueStoneIM/PreloginBootstrap/\(scopeHash)/last-good.json"
            )
        // APP1 and APP2 deliberately use different bundle identifiers and must
        // never share their anti-rollback checkpoint or local device identity.
        // No shared Keychain access group is configured.
        keychainService = Self.keychainServiceName(bundleIdentifier: bundleIdentifier)
        keychainAccount = scopeHash
    }

    static func keychainServiceName(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).prelogin-bootstrap"
    }

    func loadEnvelope() throws -> PreloginLastGoodEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try JSONDecoder().decode(PreloginLastGoodEnvelope.self, from: data)
    }

    func loadCheckpoint() throws -> PreloginTrustCheckpoint? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        return try JSONDecoder().decode(PreloginTrustCheckpoint.self, from: data)
    }

    func saveEnvelope(_ value: PreloginLastGoodEnvelope) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func saveCheckpoint(_ value: PreloginTrustCheckpoint) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw PreloginBootstrapError.allSourcesUnavailable
            }
        } else if updateStatus != errSecSuccess {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
    }
}

protocol PreloginHTTPFetching: Sendable {
    func get(_ url: URL, constrainedTo seed: PreloginSeed) async throws -> Data
}

enum PreloginRedirectPolicy {
    static func requestToFollow(
        originalURL: URL?,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        _ = originalURL
        _ = proposedRequest
        // Bootstrap objects are immutable, source-bound trust inputs. Following
        // even a same-origin redirect would make the fetched object differ from
        // the URL constrained and audited by the caller.
        return nil
    }
}

private final class PreloginNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            PreloginRedirectPolicy.requestToFollow(
                originalURL: task.originalRequest?.url,
                proposedRequest: request
            )
        )
    }
}

final class PreloginHTTPSClient: PreloginHTTPFetching, @unchecked Sendable {
    private let delegate: PreloginNoRedirectDelegate
    private let session: URLSession

    init() {
        delegate = PreloginNoRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func get(_ url: URL, constrainedTo seed: PreloginSeed) async throws -> Data {
        guard Self.isWithinSourceForBootstrap(url, seed: seed) else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url == url,
              http.url?.scheme == "https",
              http.expectedContentLength <= Int64(PreloginStrictJSON.maxBytes)
                || http.expectedContentLength == NSURLSessionTransferSizeUnknown else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < PreloginStrictJSON.maxBytes else {
                throw PreloginBootstrapError.allSourcesUnavailable
            }
            data.append(byte)
        }
        return data
    }

    fileprivate static func isWithinSourceForBootstrap(_ url: URL, seed: PreloginSeed) -> Bool {
        guard url.scheme == "https",
              url.host?.lowercased() == seed.baseURL.host?.lowercased(),
              (url.port ?? 443) == (seed.baseURL.port ?? 443),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        let basePath = normalizedBasePath(seed.baseURL.path)
        return url.path.hasPrefix(basePath)
    }

    private static func normalizedBasePath(_ path: String) -> String {
        let base = path.isEmpty ? "/" : path
        return base.hasSuffix("/") ? base : "\(base)/"
    }
}

private struct PreloginSourceDocuments: Sendable {
    let seed: PreloginSeed
    let currentRaw: Data
}

private struct PreloginVerifiedSourceChain: Sendable {
    let sourceID: String
    let keyState: PreloginVerifiedKeyState
    let current: PreloginVerifiedCurrent
    let artifact: PreloginVerifiedArtifact?
}

private struct PreloginResolvedCandidate: Sendable {
    let sourceID: String
    let artifact: PreloginVerifiedArtifact
    let keyState: PreloginVerifiedKeyState
    let current: PreloginVerifiedCurrent
}

actor PreloginBootstrapResolver {
    private let configuration: PreloginBootstrapConfiguration
    private let fetcher: any PreloginHTTPFetching
    private let store: any PreloginLastGoodStoring
    private let now: @Sendable () -> Date
    private let maxOffline: TimeInterval

    init(
        configuration: PreloginBootstrapConfiguration,
        fetcher: any PreloginHTTPFetching = PreloginHTTPSClient(),
        store: (any PreloginLastGoodStoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        maxOffline: TimeInterval = 24 * 3600
    ) {
        self.configuration = configuration
        self.fetcher = fetcher
        let scopeHash = PreloginTrust.scopeHash(configuration.scope)
        self.store = store ?? PreloginSecureLastGoodStore(scopeHash: scopeHash)
        self.now = now
        self.maxOffline = max(0, min(maxOffline, PreloginTrust.maxArtifactLifetime))
    }

    func resolvePlatformBase() async throws -> URL {
        try configuration.validate()
        let currentTime = now()
        let checkpoint = try await store.loadCheckpoint()
        // A damaged cache file is recoverable from valid network sources. The
        // Keychain checkpoint is not optional in the same way: silently
        // discarding it would reopen recovery/fencing rollback.
        let envelope = try? await store.loadEnvelope()
        let scopeHash = PreloginTrust.scopeHash(configuration.scope)
        if let checkpoint {
            guard checkpoint.scopeHash == scopeHash else {
                throw PreloginBootstrapError.scopeMismatch
            }
            if currentTime.addingTimeInterval(PreloginTrust.allowedClockSkew)
                < checkpoint.lastTrustedWallClock {
                throw PreloginBootstrapError.clockRollback
            }
        }

        let networkResult = await resolveFromNetwork(
            checkpoint: checkpoint,
            now: currentTime
        )
        switch networkResult {
        case let .success(candidate):
            try validateCheckpointTransition(candidate.artifact, previous: checkpoint)
            let newEnvelope = PreloginLastGoodEnvelope(
                scopeHash: scopeHash,
                artifact: candidate.artifact.raw,
                keyState: candidate.keyState.raw,
                currentPointer: candidate.current.raw,
                savedAt: currentTime
            )
            let newCheckpoint = PreloginTrustCheckpoint(
                scopeHash: scopeHash,
                recoveryGeneration: candidate.keyState.state.payload.recoveryGeneration,
                recoveryHash: candidate.keyState.payloadHash,
                fencingGeneration: candidate.artifact.artifact.payload.fencingGeneration,
                configVersion: candidate.artifact.artifact.payload.configVersion,
                payloadHash: candidate.artifact.payloadHash,
                lastTrustedWallClock: max(
                    currentTime,
                    checkpoint?.lastTrustedWallClock ?? currentTime
                ),
                lastNetworkSavedAt: currentTime
            )
            // Persist signed material first. A crash before checkpoint advance can
            // be healed by the next network resolution; the reverse order could
            // strand an older envelope behind a newer anti-rollback checkpoint.
            try await store.saveEnvelope(newEnvelope)
            try await store.saveCheckpoint(newCheckpoint)
            return try PreloginTrust.platformBase(from: candidate.artifact)
        case let .failure(error):
            if isFailClosed(error) { throw error }
            let cached = try await resolveLastGood(
                envelope: envelope,
                checkpoint: checkpoint,
                now: currentTime
            )
            if let checkpoint {
                try await store.saveCheckpoint(
                    PreloginTrustCheckpoint(
                        scopeHash: checkpoint.scopeHash,
                        recoveryGeneration: checkpoint.recoveryGeneration,
                        recoveryHash: checkpoint.recoveryHash,
                        fencingGeneration: checkpoint.fencingGeneration,
                        configVersion: checkpoint.configVersion,
                        payloadHash: checkpoint.payloadHash,
                        lastTrustedWallClock: max(
                            checkpoint.lastTrustedWallClock,
                            currentTime
                        ),
                        lastNetworkSavedAt: checkpoint.lastNetworkSavedAt
                    )
                )
            }
            return cached
        }
    }

    private func resolveFromNetwork(
        checkpoint: PreloginTrustCheckpoint?,
        now: Date
    ) async -> Result<PreloginResolvedCandidate, Error> {
        var documents: [PreloginSourceDocuments] = []
        await withTaskGroup(of: PreloginSourceDocuments?.self) { group in
            for seed in configuration.seeds {
                group.addTask { [configuration, fetcher] in
                    let scopeHash = PreloginTrust.scopeHash(configuration.scope)
                    guard let currentURL = try? Self.scopedObjectURL(
                        "current.json",
                        scopeHash: scopeHash,
                        seed: seed
                    ) else {
                        return nil
                    }
                    guard let current = try? await fetcher.get(
                        currentURL,
                        constrainedTo: seed
                    ) else { return nil }
                    return PreloginSourceDocuments(seed: seed, currentRaw: current)
                }
            }
            for await item in group {
                if let item { documents.append(item) }
            }
        }
        guard !documents.isEmpty else {
            return .failure(PreloginBootstrapError.allSourcesUnavailable)
        }

        var chains: [PreloginVerifiedSourceChain] = []
        await withTaskGroup(of: PreloginVerifiedSourceChain?.self) { group in
            for item in documents {
                group.addTask { [configuration, fetcher] in
                    do {
                        let reference = try PreloginTrust.keyStateReference(
                            currentRaw: item.currentRaw,
                            scope: configuration.scope
                        )
                        let keyStateRaw = try await fetcher.get(
                            try Self.objectURL(reference.key, seed: item.seed),
                            constrainedTo: item.seed
                        )
                        let state = try PreloginTrust.verifyKeyState(
                            raw: keyStateRaw,
                            rootKeyID: configuration.rootKeyID,
                            rootPublicKey: configuration.rootPublicKey,
                            previousRecoveryGeneration: 0,
                            previousHash: "",
                            now: now
                        )
                        guard state.objectHash == reference.hash else {
                            throw PreloginBootstrapError.currentPointerInvalid
                        }
                        let current = try PreloginTrust.verifyCurrent(
                            raw: item.currentRaw,
                            scope: configuration.scope,
                            keyState: state,
                            publicKeys: configuration.artifactPublicKeys,
                            now: now
                        )
                        let artifact: PreloginVerifiedArtifact?
                        do {
                            let artifactRaw = try await fetcher.get(
                                try Self.objectURL(
                                    current.pointer.payload.artifactKey,
                                    seed: item.seed
                                ),
                                constrainedTo: item.seed
                            )
                            let verified = try PreloginTrust.verifyArtifact(
                                raw: artifactRaw,
                                scope: configuration.scope,
                                keyState: state,
                                publicKeys: configuration.artifactPublicKeys,
                                now: now
                            )
                            try PreloginTrust.verifyPointerArtifactBinding(
                                pointer: current,
                                artifact: verified
                            )
                            artifact = verified
                        } catch {
                            artifact = nil
                        }
                        return PreloginVerifiedSourceChain(
                            sourceID: item.seed.id,
                            keyState: state,
                            current: current,
                            artifact: artifact
                        )
                    } catch {
                        return nil
                    }
                }
            }
            for await item in group {
                if let item { chains.append(item) }
            }
        }
        guard !chains.isEmpty else {
            return .failure(PreloginBootstrapError.noValidCandidate)
        }
        do {
            if let checkpoint,
               chains.contains(where: {
                   $0.keyState.state.payload.recoveryGeneration == checkpoint.recoveryGeneration
                       && $0.keyState.payloadHash != checkpoint.recoveryHash
               }) {
                throw PreloginBootstrapError.recoveryConflict
            }
            let eligibleChains = chains.filter {
                guard let checkpoint else { return true }
                return $0.keyState.state.payload.recoveryGeneration >= checkpoint.recoveryGeneration
                    && $0.keyState.state.payload.currentFencingGeneration >= checkpoint.fencingGeneration
            }
            guard !eligibleChains.isEmpty else {
                throw PreloginBootstrapError.recoveryRollback
            }
            let highestRecovery = eligibleChains.map {
                $0.keyState.state.payload.recoveryGeneration
            }.max() ?? 0
            let recoveryWinners = eligibleChains.filter {
                $0.keyState.state.payload.recoveryGeneration == highestRecovery
            }
            guard Set(recoveryWinners.map(\.keyState.payloadHash)).count == 1 else {
                throw PreloginBootstrapError.recoveryConflict
            }
            let ordered = recoveryWinners.sorted {
                let left = $0.current.pointer.payload
                let right = $1.current.pointer.payload
                if left.fencingGeneration != right.fencingGeneration {
                    return left.fencingGeneration > right.fencingGeneration
                }
                return left.configVersion > right.configVersion
            }
            guard let first = ordered.first else {
                throw PreloginBootstrapError.noValidCandidate
            }
            let winningPayload = first.current.pointer.payload
            let sameVersion = ordered.filter {
                $0.current.pointer.payload.fencingGeneration == winningPayload.fencingGeneration
                    && $0.current.pointer.payload.configVersion == winningPayload.configVersion
            }
            guard sameVersion.allSatisfy({ $0.current.pointer == first.current.pointer }) else {
                throw PreloginBootstrapError.candidateConflict
            }
            guard let winner = sameVersion.first(where: { $0.artifact != nil }),
                  let artifact = winner.artifact else {
                throw PreloginBootstrapError.keyUnauthorized
            }
            return .success(
                PreloginResolvedCandidate(
                    sourceID: winner.sourceID,
                    artifact: artifact,
                    keyState: winner.keyState,
                    current: winner.current
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func resolveLastGood(
        envelope: PreloginLastGoodEnvelope?,
        checkpoint: PreloginTrustCheckpoint?,
        now: Date
    ) async throws -> URL {
        guard let envelope, let checkpoint,
              envelope.scopeHash == checkpoint.scopeHash,
              abs(envelope.savedAt.timeIntervalSince(checkpoint.lastNetworkSavedAt))
                <= PreloginTrust.allowedClockSkew,
              now >= checkpoint.lastNetworkSavedAt.addingTimeInterval(
                -PreloginTrust.allowedClockSkew
              ),
              now.timeIntervalSince(checkpoint.lastNetworkSavedAt) <= maxOffline else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        let state = try PreloginTrust.verifyKeyState(
            raw: envelope.keyState,
            rootKeyID: configuration.rootKeyID,
            rootPublicKey: configuration.rootPublicKey,
            previousRecoveryGeneration: checkpoint.recoveryGeneration,
            previousHash: checkpoint.recoveryHash,
            now: now
        )
        let current = try PreloginTrust.verifyCurrent(
            raw: envelope.currentPointer,
            scope: configuration.scope,
            keyState: state,
            publicKeys: configuration.artifactPublicKeys,
            now: now
        )
        let artifact = try PreloginTrust.verifyArtifact(
            raw: envelope.artifact,
            scope: configuration.scope,
            keyState: state,
            publicKeys: configuration.artifactPublicKeys,
            now: now
        )
        try PreloginTrust.verifyPointerArtifactBinding(pointer: current, artifact: artifact)
        try validateCheckpointTransition(artifact, previous: checkpoint)
        guard state.state.payload.recoveryGeneration == checkpoint.recoveryGeneration,
              state.payloadHash == checkpoint.recoveryHash,
              artifact.artifact.payload.fencingGeneration == checkpoint.fencingGeneration,
              artifact.artifact.payload.configVersion == checkpoint.configVersion,
              artifact.payloadHash == checkpoint.payloadHash else {
            throw PreloginBootstrapError.recoveryRollback
        }
        return try PreloginTrust.platformBase(from: artifact)
    }

    private func validateCheckpointTransition(
        _ artifact: PreloginVerifiedArtifact,
        previous: PreloginTrustCheckpoint?
    ) throws {
        guard let previous else { return }
        let payload = artifact.artifact.payload
        if payload.fencingGeneration < previous.fencingGeneration
            || payload.fencingGeneration == previous.fencingGeneration
                && payload.configVersion < previous.configVersion {
            throw PreloginBootstrapError.recoveryRollback
        }
        if payload.fencingGeneration == previous.fencingGeneration,
           payload.configVersion == previous.configVersion,
           artifact.payloadHash != previous.payloadHash {
            throw PreloginBootstrapError.candidateConflict
        }
    }

    private func isFailClosed(_ error: Error) -> Bool {
        guard let typed = error as? PreloginBootstrapError else { return false }
        return [
            .candidateConflict,
            .recoveryConflict,
            .recoveryRollback,
            .clockRollback,
            .keyUnauthorized
        ].contains(typed)
    }

    private static func scopedObjectURL(
        _ leaf: String,
        scopeHash: String,
        seed: PreloginSeed
    ) throws -> URL {
        guard leaf == "current.json",
              scopeHash.utf8.count == 64 else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        return try objectURL(
            "bootstrap-v1/\(scopeHash)/\(leaf)",
            seed: seed
        )
    }

    private static func objectURL(_ object: String, seed: PreloginSeed) throws -> URL {
        guard object.hasPrefix("bootstrap-v1/"),
              object.dropFirst("bootstrap-v1/".count).range(of: "bootstrap-v1/") == nil,
              !object.hasPrefix("/"),
              !object.contains("\\"),
              !object.contains("?"),
              !object.contains("#"),
              !object.contains("%"),
              !object.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        var base = seed.baseURL
        if !base.path.hasSuffix("/") { base.appendPathComponent("") }
        let result = base.appendingPathComponent(object)
        guard PreloginHTTPSClient.isWithinSourceForBootstrap(result, seed: seed) else {
            throw PreloginBootstrapError.allSourcesUnavailable
        }
        return result
    }
}

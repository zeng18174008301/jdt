import CryptoKit
import Foundation
import Network

@MainActor
protocol AccessDiscoveryFetching: AnyObject, Sendable {
    func accessDiscoveryEndpoints(context: IMAPIContext) async throws -> RemoteAccessDiscoveryResponse
    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse
}

extension AccessDiscoveryFetching {
    func accessDiscoveryEndpoints(
        context: IMAPIContext,
        endpointURL: URL?,
        timeoutInterval: TimeInterval
    ) async throws -> RemoteAccessDiscoveryResponse {
        guard endpointURL == nil else {
            throw AccessDiscoveryTrustError.endpointInvalid
        }
        return try await accessDiscoveryEndpoints(context: context)
    }
}

protocol AccessDiscoveryManaging: AnyObject, Sendable {
    @discardableResult
    func refresh(context: IMAPIContext, fetcher: AccessDiscoveryFetching, force: Bool) async -> AccessDiscoveryRefreshOutcome
    func realtimeConnectionRequest(
        context: IMAPIContext,
        token: String,
        fallbackURL: URL?,
        quicConfiguration: RealtimeQUICConfiguration
    ) -> RealtimeConnectionRequest?
    func markActiveRealtimeEndpointFailed()
    func markActiveRealtimeEndpointConnected()
    func markActiveRealtimeEndpointSucceeded()
}

enum AccessDiscoveryRefreshOutcome: Equatable {
    case memory(configVersion: String)
    case network(configVersion: String)
    case cache(configVersion: String)
    case unavailable
}

func accessDiscoveryTrustedTransitionAllowed(
    previous: RemoteAccessDiscoveryResponse?,
    candidate: RemoteAccessDiscoveryResponse
) -> Bool {
    guard let candidateTrust = candidate.trust else { return false }
    guard let previousTrust = previous?.trust else { return true }
    if candidate.contractVersion == 2 {
        guard let candidateRevision = candidate.publicationRevision,
              let candidatePublicationID = candidate.publicationID,
              let candidateFingerprint = candidate.profileFingerprint,
              let candidateStatus = candidate.publicationStatus,
              let candidateKeysetRevision = candidate.keysetRevision else {
            return false
        }
        if previous?.contractVersion == 2 {
            guard let previousRevision = previous?.publicationRevision,
                  let previousPublicationID = previous?.publicationID,
                  let previousFingerprint = previous?.profileFingerprint,
                  let previousStatus = previous?.publicationStatus,
                  let previousKeysetRevision = previous?.keysetRevision,
                  candidateRevision >= previousRevision,
                  candidateKeysetRevision >= previousKeysetRevision,
                  candidateTrust.recoveryGeneration >= previousTrust.recoveryGeneration,
                  candidateTrust.fencingGeneration >= previousTrust.fencingGeneration else {
                return false
            }
            if candidateTrust.recoveryGeneration == previousTrust.recoveryGeneration,
               candidateTrust.keyStateHash != previousTrust.keyStateHash {
                return false
            }
            if candidateTrust.recoveryGeneration > previousTrust.recoveryGeneration,
               candidateTrust.keyStateHash == previousTrust.keyStateHash {
                return false
            }
            if candidateRevision == previousRevision {
                return candidatePublicationID == previousPublicationID
                    && candidateFingerprint == previousFingerprint
                    && candidateStatus == previousStatus
                    && candidateTrust.contentHash == previousTrust.contentHash
                    && candidateKeysetRevision == previousKeysetRevision
            }
            return true
        }
        return true
    }
    if previous?.contractVersion == 2 { return false }
    if candidateTrust.recoveryGeneration < previousTrust.recoveryGeneration ||
        candidateTrust.fencingGeneration < previousTrust.fencingGeneration ||
        candidateTrust.generation < previousTrust.generation {
        return false
    }
    if candidateTrust.recoveryGeneration == previousTrust.recoveryGeneration,
       candidateTrust.keyStateHash != previousTrust.keyStateHash {
        return false
    }
    if candidateTrust.recoveryGeneration > previousTrust.recoveryGeneration,
       candidateTrust.keyStateHash == previousTrust.keyStateHash {
        return false
    }
    if candidateTrust.fencingGeneration > previousTrust.fencingGeneration {
        return true
    }
    if candidateTrust.generation == previousTrust.generation,
       (candidateTrust.contentHash != previousTrust.contentHash ||
        candidate.configVersion != previous?.configVersion) {
        return false
    }
    if candidate.configVersion == previous?.configVersion,
       candidateTrust.contentHash != previousTrust.contentHash {
        return false
    }
    return true
}
final class AccessDiscoveryManager: AccessDiscoveryManaging, @unchecked Sendable {
    private static let totalDiscoveryDeadlineSeconds: TimeInterval = 8
    private static let requestDeadlineSeconds: TimeInterval = 2.5
    private static let maximumDiscoveryFallbacks = 3
    private let store: AccessDiscoveryStore
    private let nowProvider: () -> Date
    private let monotonicNowProvider: () -> TimeInterval
    private let randomProvider: () -> Double
    private let trustConfiguration: AccessDiscoveryTrustConfiguration
    private let verifiedResponseProvider: ((RemoteAccessDiscoveryResponse, IMAPIContext, Date) throws -> RemoteAccessDiscoveryResponse)?
    private let lock = NSRecursiveLock()
    private var snapshots: [String: AccessDiscoveryCachedSnapshot] = [:]
    private var activeCacheKey: String?
    private var activeEndpointID: String?
    private var activeStartedAt: TimeInterval?
    private var directFailbackUntilByKey: [String: TimeInterval] = [:]
    private var terminallyUnavailableKeys: Set<String> = []
    private var trustConfigurationBlockedKeys: Set<String> = []

    init(
        store: AccessDiscoveryStore = AccessDiscoveryStore(),
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        trustConfiguration: AccessDiscoveryTrustConfiguration = .load(),
        verifiedResponseProvider: ((RemoteAccessDiscoveryResponse, IMAPIContext, Date) throws -> RemoteAccessDiscoveryResponse)? = nil
    ) {
        self.store = store
        self.nowProvider = now
        self.monotonicNowProvider = monotonicNow
        self.randomProvider = random
        self.trustConfiguration = trustConfiguration
        self.verifiedResponseProvider = verifiedResponseProvider
    }

    @discardableResult
    func refresh(context: IMAPIContext, fetcher: AccessDiscoveryFetching, force: Bool = false) async -> AccessDiscoveryRefreshOutcome {
        let key = cacheKey(for: context)
        let now = nowProvider().timeIntervalSince1970
        if !force,
           let cached = usableSnapshot(for: key, context: context),
           cached.expiresAt > now {
            return .memory(configVersion: cached.response.configVersion)
        }
        if !force,
           let persisted = loadPersistedSnapshot(for: key, context: context),
           persisted.expiresAt > now {
            return .cache(configVersion: persisted.response.configVersion)
        }
        if lock.withLock({ trustConfigurationBlockedKeys.contains(key) }) {
            return loadPersistedOutcome(for: key, context: context)
        }

        let trustedPrevious = usableSnapshot(for: key, context: context) ??
            loadPersistedSnapshot(for: key, context: context)
        let fallbackURLs = trustConfiguration.required
            ? Self.trustedDiscoveryFallbackURLs(from: trustedPrevious?.response)
            : []
        let deadline = monotonicNowProvider() + Self.totalDiscoveryDeadlineSeconds
        var lastError: Error?
        for endpointURL in [URL?.none] + fallbackURLs.map(Optional.some) {
            if Task.isCancelled { return .unavailable }
            let remaining = deadline - monotonicNowProvider()
            if remaining <= 0 { break }
            do {
                let fetched = try await fetcher.accessDiscoveryEndpoints(
                    context: context,
                    endpointURL: endpointURL,
                    timeoutInterval: min(Self.requestDeadlineSeconds, remaining)
                )
                let response = try validatedFetchedResponse(fetched, context: context)
                guard transitionAllowed(from: trustedPrevious, to: response),
                      advanceKnownKeyset(response, context: context),
                      advanceTrustWatermark(response, context: context) else {
                    throw AccessDiscoveryTrustError.rollback
                }
                if response.contractVersion == 2,
                   ["disabled", "tombstone"].contains(response.publicationStatus ?? "") {
                    markTerminallyUnavailable(key: key)
                    return .unavailable
                }
                guard Self.isPersistable(response) else {
                    throw AccessDiscoveryTrustError.endpointInvalid
                }
                var cached = makeCachedSnapshot(response: response, key: key, now: now)
                lock.withLock {
                    let previous = snapshots[key]
                    let versionChanged = previous.map { $0.response.configVersion != response.configVersion } ?? false
                    if versionChanged {
                        directFailbackUntilByKey[key] = nil
                    } else if let previousHealth = previous?.health {
                        cached.health = previousHealth
                    }
                    snapshots[key] = cached
                    terminallyUnavailableKeys.remove(key)
                }
                do {
                    try store.save(cached, key: key)
                } catch {
                    markTerminallyUnavailable(key: key)
                    return .unavailable
                }
                return .network(configVersion: response.configVersion)
            } catch {
                if Task.isCancelled { return .unavailable }
                if (error as? AccessDiscoveryTrustError) == .configurationBlocked {
                    let firstFailure = lock.withLock { trustConfigurationBlockedKeys.insert(key).inserted }
                    if firstFailure {
                        print("[JHT Access] access_discovery_trust_configuration_blocked")
                    }
                    break
                }
                if Self.isTerminalDiscoveryError(error), !trustConfiguration.required {
                    markTerminallyUnavailable(key: key)
                    return .unavailable
                }
                lastError = error
                guard Self.shouldAttemptTrustedDiscoveryFallback(after: error) else {
                    break
                }
            }
        }
        _ = lastError
        return loadPersistedOutcome(for: key, context: context)
    }

    func realtimeConnectionRequest(
        context: IMAPIContext,
        token: String,
        fallbackURL: URL?,
        quicConfiguration: RealtimeQUICConfiguration = RealtimeQUICConfiguration.load()
    ) -> RealtimeConnectionRequest? {
        let key = cacheKey(for: context)
        let now = nowProvider().timeIntervalSince1970
        let fallbackURL = fallbackURL.map {
            RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: $0)
        }
#if DEBUG
        if !trustConfiguration.required,
           let fallbackURL,
           Self.isDevelopmentLoopbackFallbackURL(fallbackURL) {
            clearActiveRealtimeEndpoint()
            return RealtimeConnectionRequest(url: fallbackURL, token: token)
        }
#endif
        guard !isTerminallyUnavailable(key: key) else {
            if trustConfiguration.required { return nil }
            guard let fallbackURL else { return nil }
            clearActiveRealtimeEndpoint()
            return RealtimeConnectionRequest(url: fallbackURL, token: token)
        }
        if let snapshot = usableSnapshot(for: key, context: context) ??
            loadPersistedSnapshot(for: key, context: context) {
            let webSocketEndpoint = selectRealtimeEndpoint(
                from: snapshot,
                key: key,
                now: now,
                isCandidate: { $0.isRealtimeWebSocketCandidate }
            )
            let quicEndpoint = quicConfiguration.isEnabled
                ? selectRealtimeEndpoint(
                    from: snapshot,
                    key: key,
                    now: now,
                    isCandidate: { $0.isRealtimeQUICCandidate }
                )
                : nil
            let url = webSocketEndpoint?.runtimeWebSocketURL() ??
                (trustConfiguration.required ? nil : fallbackURL)
            guard let url else { return nil }
            let webSocketDialMetadata = webSocketEndpoint?.runtimeWebSocketDialMetadata()
            let quicRequest = quicEndpoint?.runtimeQUICConnectionRequest(token: token, configuration: quicConfiguration)
            lock.lock()
            activeCacheKey = key
            activeEndpointID = quicRequest == nil ? webSocketEndpoint?.normalizedID : quicEndpoint?.normalizedID
            activeStartedAt = now
            lock.unlock()
            return RealtimeConnectionRequest(
                url: url,
                token: token,
                webSocketDialMetadata: webSocketDialMetadata,
                quicRequest: quicRequest
            )
        }
        guard !trustConfiguration.required, let fallbackURL else { return nil }
        lock.lock()
        activeCacheKey = nil
        activeEndpointID = nil
        activeStartedAt = nil
        lock.unlock()
        return RealtimeConnectionRequest(url: fallbackURL, token: token)
    }

    private func clearActiveRealtimeEndpoint() {
        lock.lock()
        activeCacheKey = nil
        activeEndpointID = nil
        activeStartedAt = nil
        lock.unlock()
    }

    func markActiveRealtimeEndpointFailed() {
        let now = nowProvider().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let key = activeCacheKey,
              let endpointID = activeEndpointID,
              var snapshot = snapshots[key],
              let endpoint = snapshot.response.endpoints.first(where: { $0.normalizedID == endpointID }) else {
            activeCacheKey = nil
            activeEndpointID = nil
            activeStartedAt = nil
            return
        }
        var health = snapshot.health[endpointID] ?? AccessDiscoveryEndpointHealth()
        health.failureCount += 1
        let connectedAt = health.lastConnectedAt ?? activeStartedAt ?? now
        if now - connectedAt < 30 {
            health.quickDisconnectCount += 1
        }
        let cooldownSeconds = cooldownDurationSeconds(for: endpoint, health: health)
        if cooldownSeconds > 0 {
            health.cooldownUntil = now + cooldownSeconds
        }
        snapshot.health[endpointID] = health
        snapshots[key] = snapshot
        try? store.save(snapshot, key: key)
        activeCacheKey = nil
        activeEndpointID = nil
        activeStartedAt = nil
    }

    func markActiveRealtimeEndpointConnected() {
        let now = nowProvider().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let key = activeCacheKey,
              let endpointID = activeEndpointID,
              var snapshot = snapshots[key] else {
            return
        }
        var health = snapshot.health[endpointID] ?? AccessDiscoveryEndpointHealth()
        health.lastConnectedAt = now
        snapshot.health[endpointID] = health
        snapshots[key] = snapshot
        try? store.save(snapshot, key: key)
    }

    func markActiveRealtimeEndpointSucceeded() {
        let now = nowProvider().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard let key = activeCacheKey,
              let endpointID = activeEndpointID,
              var snapshot = snapshots[key],
              let endpoint = snapshot.response.endpoints.first(where: { $0.normalizedID == endpointID }) else {
            return
        }
        var health = snapshot.health[endpointID] ?? AccessDiscoveryEndpointHealth()
        health.lastConnectedAt = health.lastConnectedAt ?? now
        health.lastStableAt = now
        health.failureCount = 0
        health.quickDisconnectCount = 0
        health.cooldownUntil = nil
        if endpoint.normalizedNetwork == "direct" {
            let failback = TimeInterval(endpoint.failbackAfterSeconds ?? 300)
            let jitter = TimeInterval(max(snapshot.response.refreshJitterSeconds, 0)) * clampedRandom()
            directFailbackUntilByKey[key] = now + failback + jitter
        } else {
            directFailbackUntilByKey[key] = nil
        }
        snapshot.health[endpointID] = health
        snapshots[key] = snapshot
        try? store.save(snapshot, key: key)
    }

    private func snapshot(for key: String) -> AccessDiscoveryCachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[key]
    }

    private func usableSnapshot(
        for key: String,
        context: IMAPIContext
    ) -> AccessDiscoveryCachedSnapshot? {
        guard var snapshot = snapshot(for: key) else { return nil }
        do {
            guard knownKeysetPermits(snapshot.response, context: context) else {
                throw AccessDiscoveryTrustError.unknownKey
            }
            snapshot.response = try validatedResponse(snapshot.response, context: context)
            guard advanceTrustWatermark(snapshot.response, context: context) else {
                throw AccessDiscoveryTrustError.rollback
            }
            lock.withLock {
                snapshots[key] = snapshot
            }
            return snapshot
        } catch {
            markTerminallyUnavailable(key: key)
            return nil
        }
    }

    private func loadPersistedOutcome(for key: String, context: IMAPIContext) -> AccessDiscoveryRefreshOutcome {
        if let snapshot = loadPersistedSnapshot(for: key, context: context) {
            return .cache(configVersion: snapshot.response.configVersion)
        }
        return .unavailable
    }

    private func markTerminallyUnavailable(key: String) {
        lock.lock()
        snapshots[key] = nil
        directFailbackUntilByKey[key] = nil
        terminallyUnavailableKeys.insert(key)
        if activeCacheKey == key {
            activeCacheKey = nil
            activeEndpointID = nil
            activeStartedAt = nil
        }
        lock.unlock()
        try? store.remove(key: key)
    }

    private func isTerminallyUnavailable(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminallyUnavailableKeys.contains(key)
    }

    private func loadPersistedSnapshot(for key: String, context: IMAPIContext) -> AccessDiscoveryCachedSnapshot? {
        guard var snapshot = try? store.load(key: key),
              knownKeysetPermits(snapshot.response, context: context),
              let validated = try? validatedResponse(snapshot.response, context: context),
              Self.isPersistable(validated),
              advanceTrustWatermark(validated, context: context) else {
            if trustConfiguration.required {
                try? store.remove(key: key)
            }
            return nil
        }
        snapshot.response = validated
        lock.lock()
        snapshots[key] = snapshot
        lock.unlock()
        return snapshot
    }

    private func validatedResponse(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) throws -> RemoteAccessDiscoveryResponse {
        if !trustConfiguration.required {
            return response
        }
        if let verifiedResponseProvider {
            return try verifiedResponseProvider(response, context, nowProvider())
        }
        return try trustConfiguration.verifyStored(response, context: context, now: nowProvider())
    }

    private func validatedFetchedResponse(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) throws -> RemoteAccessDiscoveryResponse {
        if !trustConfiguration.required { return response }
        if let verifiedResponseProvider {
            return try verifiedResponseProvider(response, context, nowProvider())
        }
        return try trustConfiguration.verifyNetworkResponse(
            response,
            context: context,
            now: nowProvider()
        )
    }

    private func transitionAllowed(
        from previous: AccessDiscoveryCachedSnapshot?,
        to candidate: RemoteAccessDiscoveryResponse
    ) -> Bool {
        guard trustConfiguration.required else { return true }
        return accessDiscoveryTrustedTransitionAllowed(previous: previous?.response, candidate: candidate)
    }

    private func advanceTrustWatermark(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) -> Bool {
        guard trustConfiguration.required else { return true }
        guard let watermark = AccessDiscoveryTrustWatermark(response: response) else { return false }
        do {
            return try store.advanceTrustWatermark(
                watermark,
                key: trustWatermarkKey(for: context)
            )
        } catch {
            return false
        }
    }

    private func advanceKnownKeyset(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) -> Bool {
        guard trustConfiguration.required else { return true }
        guard response.contractVersion == 2 else { return true }
        guard let keyset = AccessDiscoveryKnownKeyset(response: response) else { return false }
        do {
            return try store.advanceKnownKeyset(keyset, key: trustWatermarkKey(for: context))
        } catch {
            return false
        }
    }

    private func knownKeysetPermits(
        _ response: RemoteAccessDiscoveryResponse,
        context: IMAPIContext
    ) -> Bool {
        guard trustConfiguration.required,
              response.contractVersion == 2,
              let signingKeyID = response.trust?.keyID else {
            return !trustConfiguration.required || response.contractVersion != 2
        }
        guard let keyset = try? store.loadKnownKeyset(key: trustWatermarkKey(for: context)) else {
            return true
        }
        return keyset.permitsHistoricalLastGood(signedBy: signingKeyID)
    }

    private func trustWatermarkKey(for context: IMAPIContext) -> String {
        [
            "v2",
            trustConfiguration.environment,
            trustConfiguration.appID,
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ].joined(separator: "|")
    }

    private func makeCachedSnapshot(response: RemoteAccessDiscoveryResponse, key: String, now: TimeInterval) -> AccessDiscoveryCachedSnapshot {
        let ttl = TimeInterval(max(response.ttlSeconds, 30))
        let staleWindow = max(ttl, 86_400)
        return AccessDiscoveryCachedSnapshot(
            response: response,
            fetchedAt: now,
            expiresAt: now + ttl,
            staleUntil: now + staleWindow,
            health: [:]
        )
    }

    private func selectRealtimeEndpoint(
        from snapshot: AccessDiscoveryCachedSnapshot,
        key: String,
        now: TimeInterval,
        isCandidate: (RemoteAccessDiscoveryEndpoint) -> Bool
    ) -> RemoteAccessDiscoveryEndpoint? {
        let candidates = snapshot.response.endpoints.filter {
            isCandidate($0) && ($0.normalizedStatus == "ready" || $0.normalizedStatus == "degraded")
        }
        guard !candidates.isEmpty else { return nil }

        if let holdUntil = directFailbackUntilByKey[key],
           holdUntil > now,
           let activeID = activeEndpointID,
           let direct = candidates.first(where: {
               $0.normalizedID == activeID
                   && $0.normalizedNetwork == "direct"
                   && !isCooling($0, snapshot: snapshot, now: now)
           }) {
            return direct
        }

        let ready = candidates.filter { $0.normalizedStatus == "ready" }
        let preferredStatusCandidates = ready.isEmpty ? candidates : ready
        let notCooling = preferredStatusCandidates.filter { !isCooling($0, snapshot: snapshot, now: now) }
        guard !notCooling.isEmpty else { return nil }
        let selectable = notCooling
        let sorted = selectable.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.normalizedID < rhs.normalizedID
        }
        guard let first = sorted.first else { return nil }
        let topPriority = first.priority
        let weightedGroup = sorted.filter { $0.priority == topPriority }
        return weightedPick(from: weightedGroup) ?? first
    }

    private func weightedPick(from endpoints: [RemoteAccessDiscoveryEndpoint]) -> RemoteAccessDiscoveryEndpoint? {
        guard !endpoints.isEmpty else { return nil }
        let totalWeight = endpoints.reduce(0) { $0 + max($1.weight, 0) }
        guard totalWeight > 0 else { return endpoints.first }
        var threshold = clampedRandom() * Double(totalWeight)
        for endpoint in endpoints {
            threshold -= Double(max(endpoint.weight, 0))
            if threshold <= 0 {
                return endpoint
            }
        }
        return endpoints.last
    }

    private func isCooling(
        _ endpoint: RemoteAccessDiscoveryEndpoint,
        snapshot: AccessDiscoveryCachedSnapshot,
        now: TimeInterval
    ) -> Bool {
        snapshot.health[endpoint.normalizedID]?.isCoolingDown(at: now) == true
    }

    private func cooldownDurationSeconds(
        for endpoint: RemoteAccessDiscoveryEndpoint,
        health: AccessDiscoveryEndpointHealth
    ) -> TimeInterval {
        if let cooldownSeconds = endpoint.cooldownSeconds, cooldownSeconds > 0 {
            return TimeInterval(cooldownSeconds)
        }
        let escalation: [TimeInterval] = [300, 900, 1_800]
        let index = min(max(health.failureCount - 1, 0), escalation.count - 1)
        return escalation[index]
    }

    private func clampedRandom() -> Double {
        min(max(randomProvider(), 0), 0.999_999)
    }

    private static func isPersistable(_ response: RemoteAccessDiscoveryResponse) -> Bool {
        guard [1, 2].contains(response.contractVersion),
              (response.contractVersion != 2 || response.publicationStatus == "active"),
              !response.configVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return response.endpoints.contains {
            $0.normalizedStatus == "ready" && $0.isRealtimeWebSocketCandidate
        }
    }

    static func trustedDiscoveryFallbackURLs(
        from response: RemoteAccessDiscoveryResponse?
    ) -> [URL] {
        guard let response else { return [] }
        var seen = Set<String>()
        return response.discoveryFallbacks
            .filter { endpoint in
                endpoint.protocolValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https" &&
                    endpoint.usage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "access_discovery"
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.normalizedID < $1.normalizedID
            }
            .compactMap { endpoint -> URL? in
                guard let components = URLComponents(string: endpoint.url),
                      components.scheme?.lowercased() == "https",
                      components.user == nil,
                      components.password == nil,
                      components.query == nil,
                      components.fragment == nil,
                      let host = components.host,
                      RealtimeEndpointAddressValidator.isDomainName(host),
                      host.lowercased() == endpoint.host.lowercased(),
                      let url = components.url else {
                    return nil
                }
                guard seen.insert(url.absoluteString).inserted else { return nil }
                return url
            }
            .prefix(maximumDiscoveryFallbacks)
            .map { $0 }
    }

    private static func isDevelopmentLoopbackFallbackURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else { return false }
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") else {
            return false
        }
        return url.path == "/im/ws" || url.port == 8083
    }

    private static func shouldAttemptTrustedDiscoveryFallback(after error: Error) -> Bool {
        IMAPIClient.runtimeRouteFailure(for: error).decision == .qualifiedNetwork
    }

    private static func isTerminalDiscoveryError(_ error: Error) -> Bool {
        switch error {
        case let IMAPIError.businessForbidden(code, message, apiError):
            return containsTerminalDiscoveryErrorCode(in: [code, message, apiError?.code, apiError?.reasonCode, apiError?.reason, apiError?.message])
        case let IMAPIError.conflict(code, message):
            return containsTerminalDiscoveryErrorCode(in: [code, message])
        case let IMAPIError.forbidden(message),
             let IMAPIError.server(message),
             let IMAPIError.unauthorized(message),
             let IMAPIError.badURL(message),
             let IMAPIError.missingContext(message):
            return containsTerminalDiscoveryErrorCode(in: [message])
        default:
            return false
        }
    }

    private static func containsTerminalDiscoveryErrorCode(in values: [String?]) -> Bool {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { value in
                value.contains("access_discovery_disabled")
                    || value.contains("access_discovery_tenant_mismatch")
                    || value.contains("access_discovery_app_unavailable")
            }
    }

    private func cacheKey(for context: IMAPIContext) -> String {
        [
            "v3",
            trustConfiguration.environment,
            IMAPIContext.normalizedIOSAppID(context.appID),
            context.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ].joined(separator: "|")
    }
}

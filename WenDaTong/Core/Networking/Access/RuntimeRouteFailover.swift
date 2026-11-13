import CryptoKit
import Foundation
import Network
import IM4Core
import OSLog // WDT_IOS1_HTTP_ROUTE_V5_20261113

enum IMRuntimeRouteFailureDecision: Equatable { case qualifiedNetwork, noFailover, failClosed }
enum IMRuntimeRouteFailure: Equatable {
    case dns, connect, timeout, reset, websocketHeartbeat, http(Int)
    case offline, captivePortal, authentication, business, license, cancelled, backgrounded, websocketAuth, websocketPreAckBusiness, crash
    case tlsCertificate, hostMismatch, appIDMismatch, tenantMismatch, configHashMismatch, revisionRejected, contractMismatch
    var decision: IMRuntimeRouteFailureDecision {
        switch self {
        case .dns, .connect, .timeout, .reset, .websocketHeartbeat: return .qualifiedNetwork
        case let .http(status): return [502, 503, 504].contains(status) ? .qualifiedNetwork : .noFailover
        case .tlsCertificate, .hostMismatch, .appIDMismatch, .tenantMismatch,
             .configHashMismatch, .revisionRejected, .contractMismatch: return .failClosed
        default: return .noFailover
        }
    }
}

enum IMAppBootstrapFailoverPolicy {
	static let maximumOriginCount = IMAppBootstrapHostConfiguration.maximumEffectiveBaseCount // WDT_IOS1_HTTP_ROUTE_V5_20261113
	static let perOriginFailureBudgetMS: UInt64 = 3_000
	static let maximumTotalFailureBudgetMS = UInt64(maximumOriginCount) * perOriginFailureBudgetMS

	static func decision(for failure: IMRuntimeRouteFailure) -> IMRuntimeRouteFailureDecision {
		switch failure {
		// JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
		case .dns, .connect, .timeout, .reset, .tlsCertificate,
		     .hostMismatch, .appIDMismatch, .configHashMismatch, .contractMismatch:
			return .qualifiedNetwork
		case .revisionRejected:
			return .failClosed
		case .http:
			return .qualifiedNetwork
		// JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
		default:
			// Only non-authoritative candidate failures may move to the next
			// pinned Bootstrap origin. Business terminal states still stop here.
			return .noFailover
		}
	}

	static func elapsedMS(startedAtMS: UInt64, nowMS: UInt64) -> UInt64 {
		nowMS >= startedAtMS ? nowMS - startedAtMS : 0
	}

	static func totalFailureBudgetMS(originCount: Int) -> UInt64 {
		guard originCount > 0 else { return 0 }
		return min(UInt64(originCount) * perOriginFailureBudgetMS, maximumTotalFailureBudgetMS)
	}

	static func remainingBudgetMS(
		startedAtMS: UInt64,
		nowMS: UInt64,
		budgetMS: UInt64
	) -> UInt64 {
		let elapsed = elapsedMS(startedAtMS: startedAtMS, nowMS: nowMS)
		return elapsed >= budgetMS ? 0 : budgetMS - elapsed
	}

	static func deadlineMS(startedAtMS: UInt64, budgetMS: UInt64) -> UInt64 {
		startedAtMS > UInt64.max - budgetMS ? UInt64.max : startedAtMS + budgetMS
	}
}

struct IMRuntimeTenantBinaryRouteContext: Equatable, Sendable {
	let appID: String
	let tenantID: String
	let revision: UInt64
	let activeBases: [URL]
	let standbyBases: [URL]
	let recovery: Bool
}

struct IMRuntimeTenantBinaryFetchResult: Sendable {
	let data: Data
	let statusCode: Int
	let resolvedURL: URL
}

enum IMRuntimeTenantBinaryFetchError: Error, Equatable {
	case invalidRelativePath
	case routeUnavailable
	case invalidResponse
	case httpStatus(Int)
}

enum IMRuntimeRouteTier: Equatable { case preferred, backup, failClosed }
struct IMRuntimeRouteRequestWindow: Equatable {
    let firstQualifiedFailureAtMS: UInt64?
    let tier: IMRuntimeRouteTier
    init(firstQualifiedFailureAtMS: UInt64? = nil, tier: IMRuntimeRouteTier = .preferred) {
        self.firstQualifiedFailureAtMS = firstQualifiedFailureAtMS; self.tier = tier
    }
    func recording(_ failure: IMRuntimeRouteFailure, nowMS: UInt64) -> IMRuntimeRouteRequestWindow {
        switch failure.decision {
        case .failClosed: return .init(firstQualifiedFailureAtMS: firstQualifiedFailureAtMS, tier: .failClosed)
        case .noFailover: return self
        case .qualifiedNetwork:
            let first = firstQualifiedFailureAtMS ?? nowMS
            return .init(firstQualifiedFailureAtMS: first, tier: nowMS - first >= 5_000 ? .backup : tier)
        }
    }
}

struct IMRuntimeColdLaunchAttempt: Sendable {
    let processWasNotRunning: Bool; let foregroundLaunch: Bool; let networkReachable: Bool
    let backgroundedOrCancelled: Bool; let qualifiedFailureDurationMS: UInt64
    var qualifies: Bool { processWasNotRunning && foregroundLaunch && networkReachable && !backgroundedOrCancelled && qualifiedFailureDurationMS >= 5_000 }
}

@MainActor
final class IMRuntimeColdLaunchLifecycle {
	static let shared = IMRuntimeColdLaunchLifecycle()

	private let monitor: NWPathMonitor?
	private let monitorQueue = DispatchQueue(label: "wenxintong.runtime-cold-launch.network")
	private(set) var processLaunchBegan = false
	private(set) var foregroundLaunch = false
	private(set) var networkReachable = false
	private(set) var backgroundedOrCancelled = false
	private(set) var finished = false

	init(monitorsNetwork: Bool = true) {
		monitor = monitorsNetwork ? NWPathMonitor() : nil
	}

	func beginProcessLaunch() {
		guard !processLaunchBegan else { return }
		processLaunchBegan = true
		monitor?.pathUpdateHandler = { [weak self] path in
			Task { @MainActor [weak self] in
				self?.setNetworkReachable(path.status == .satisfied)
			}
		}
		monitor?.start(queue: monitorQueue)
	}

	func sceneDidBecomeActive() {
		guard processLaunchBegan, !finished, !backgroundedOrCancelled else { return }
		foregroundLaunch = true
	}

	func sceneDidBecomeInactive() {
		guard processLaunchBegan, !finished else { return }
		foregroundLaunch = false
	}

	func sceneDidEnterBackground() {
		guard processLaunchBegan, !finished else { return }
		foregroundLaunch = false
		backgroundedOrCancelled = true
	}

	func setNetworkReachable(_ reachable: Bool) {
		networkReachable = reachable
	}

	func finish() {
		guard processLaunchBegan, !finished else { return }
		finished = true
		monitor?.cancel()
	}

	var isTracking: Bool { processLaunchBegan && !finished }

	func attempt(qualifiedFailureDurationMS: UInt64, cancelled: Bool = false) -> IMRuntimeColdLaunchAttempt {
		.init(
			processWasNotRunning: processLaunchBegan,
			foregroundLaunch: foregroundLaunch,
			networkReachable: networkReachable,
			backgroundedOrCancelled: backgroundedOrCancelled || cancelled,
			qualifiedFailureDurationMS: qualifiedFailureDurationMS
		)
	}
}

enum IMRuntimePreferredProbeKind: Equatable { case http, realtime }

final class IMRuntimeRouteSelector: @unchecked Sendable {
    private let store: IMRuntimeRouteStore
    init(store: IMRuntimeRouteStore) { self.store = store }
    func endpoints(_ snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) -> [String] {
        guard let route = snapshot.services[service.rawValue] else { return [] }
        return recovery(snapshot, service: service).recovery ? route.backups + route.preferred : route.preferred + route.backups
    }
    func endpointTiers(_ snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) -> (preferred: [String], backups: [String]) {
        guard let route = snapshot.services[service.rawValue] else { return ([], []) }
        return recovery(snapshot, service: service).recovery
            ? (route.backups, route.preferred)
            : (route.preferred, route.backups)
    }
    func recordColdLaunch(_ attempt: IMRuntimeColdLaunchAttempt, snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) {
        store.mutateRecovery(service: service, snapshot: snapshot) { state in
			guard attempt.qualifies else {
				state.consecutiveQualifiedColdLaunchFailures = 0
				return
			}
			state.consecutiveQualifiedColdLaunchFailures += 1
			state.recovery = state.recovery || state.consecutiveQualifiedColdLaunchFailures >= snapshot.policy.recoveryColdLaunchFailures
			state.consecutiveStablePreferredProbes = 0; state.lastStableProbeAtMS = nil
        }
    }
	func recordColdLaunchSuccess(snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) {
		store.mutateRecovery(service: service, snapshot: snapshot) { state in
			state.consecutiveQualifiedColdLaunchFailures = 0
		}
	}
    func recordPreferredProbe(snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService, kind: IMRuntimePreferredProbeKind,
                              succeeded: Bool, stableMS: UInt64, nowMS: UInt64, connectAcknowledged: Bool = false) {
        store.mutateRecovery(service: service, snapshot: snapshot) { state in
            guard state.recovery else { return }
            guard succeeded, stableMS >= snapshot.policy.preferredProbeStableMS, kind != .realtime || connectAcknowledged else {
                state.consecutiveStablePreferredProbes = 0; state.lastStableProbeAtMS = nil
                return
            }
            if kind == .realtime { state = .init(); return }
            guard state.lastStableProbeAtMS == nil || nowMS - state.lastStableProbeAtMS! >= snapshot.policy.preferredProbeIntervalMS else { return }
            state.consecutiveStablePreferredProbes += 1; state.lastStableProbeAtMS = nowMS
            if state.consecutiveStablePreferredProbes >= snapshot.policy.preferredProbeSuccesses { state = .init() }
        }
    }
    func recovery(_ snapshot: IMRuntimeRouteSnapshot, service: IMRuntimeRouteService) -> IMRuntimeRouteRecoveryState {
        store.record(appID: snapshot.appID, tenantID: snapshot.tenantID).recoveryByService[service.rawValue] ?? .init()
    }
}

final class IMRuntimeWebSocketContinuity: @unchecked Sendable {
	static let shared = IMRuntimeWebSocketContinuity()
    private let lock = NSLock()
	private var owner: String?; private var delivered = Set<String>(); private var deliveryOrder: [String] = []
    func acquire(_ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if owner != nil && owner != candidate { return false }; owner = candidate; return true
    }
	func release(_ candidate: String) {
		lock.lock(); defer { lock.unlock() }
		guard owner == candidate else { return }
		owner = nil
		delivered.removeAll(keepingCapacity: false)
		deliveryOrder.removeAll(keepingCapacity: false)
	}
    func accept(messageID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard delivered.insert(messageID).inserted else { return false }
        deliveryOrder.append(messageID)
        if deliveryOrder.count > 4_096 {
            let overflow = deliveryOrder.count - 4_096
            let removed = deliveryOrder.prefix(overflow)
            deliveryOrder.removeFirst(overflow)
            delivered.subtract(removed)
        }
        return true
    }
}

// WDT_IOS1_HTTP_ROUTE_V5_20261113_BEGIN
struct IMRouteV5Scope: Hashable, Sendable {
    let appID: String
    let environment: String
    let tenantID: String?
    let service: String

    var preferenceKey: String {
        let parts = [appID, environment, tenantID ?? "", service].map { "\($0.utf8.count):\($0)" }
        let digest = SHA256.hash(data: Data(parts.joined().utf8))
        return "im4.route-v5.last-success." + digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum IMRouteV5OpeningRead {
    @TaskLocal static var isActive = false
}

final class IMRouteV5Attempt: @unchecked Sendable {
    static let interval: UInt64 = 3_000_000_000
    private static let logger = Logger(subsystem: "com.wenxintong.ios", category: "http-route-v5")
    private let lock = NSLock()
    private var status: Int?
    private var raceBlocked = false // WDT_IOS1_HTTP_ROUTE_V5_20261113
    private var firstAlternativeAt: UInt64?
    private var startedAt: UInt64?
    let starts: AsyncStream<UInt64>
    private let startSignal: AsyncStream<UInt64>.Continuation

    init() {
        var continuation: AsyncStream<UInt64>.Continuation?
        starts = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        startSignal = continuation!
    }

    deinit { startSignal.finish() }

    var latestStatus: Int? { lock.withLock { status } }

    var canRace: Bool { lock.withLock { !raceBlocked } }

    var hasProvisionalSuccess: Bool {
        lock.withLock { !raceBlocked && status.map { (200..<300).contains($0) } == true }
    }

    func rejectRace() { lock.withLock { raceBlocked = true } }

    func shouldWaitForRace(after error: Error) -> Bool {
        guard !Task.isCancelled, !(error is CancellationError),
              IMAPIClient.runtimeRouteFailure(for: error).decision != .failClosed else {
            rejectRace()
            return false
        }
        return canRace && (IMAPIClient.qualifiesForHTTPRouteV5(error) || hasProvisionalSuccess)
    }

    func commitWhileSilent(_ commit: () throws -> Bool) rethrows -> Bool {
        try lock.withLock {
            guard !raceBlocked else { return false }
            return try commit()
        }
    }

    func recordAlternativeStart(_ time: UInt64, service: String) {
        let elapsed = lock.withLock {
            guard firstAlternativeAt == nil, let startedAt, time >= startedAt else { return nil as UInt64? }
            firstAlternativeAt = time
            return (time - startedAt) / 1_000_000
        }
        if let elapsed {
            Self.logger.info("alternative_start service=\(service, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)")
        }
    }

    func recordValidation(service: String) {
        let elapsed = lock.withLock {
            guard firstAlternativeAt != nil, let startedAt else { return nil as UInt64? }
            return (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        }
        if let elapsed {
            Self.logger.info("route_validated service=\(service, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)")
        }
    }

    var timing: HTTPRouteTiming { timing(onStart: { _ in }) }

    private func timing(onStart: @escaping @Sendable (UInt64) -> Void, mayStart: @escaping @Sendable () -> Bool = { true }) -> HTTPRouteTiming {
        HTTPRouteTiming(started: { [self] time in
            let first = lock.withLock {
                guard startedAt == nil else { return false }
                startedAt = time
                return true
            }
            if first {
                onStart(time)
                startSignal.yield(time)
                startSignal.finish()
            }
        }, receivedHeaders: { [self] code in
            let now = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                status = code
                let timely = startedAt.map { now < $0 &+ Self.interval } ?? true
                // A late successful header does not establish a valid business response.
                if timely || !(200..<300).contains(code) { raceBlocked = true }
            }
        }, mayStart: mayStart, failed: { [self] error in
            if !IMAPIClient.qualifiesForHTTPRouteV5(error) { rejectRace() }
        })
    }

    func finish() { startSignal.finish() }

    static func sleep(until deadline: UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < deadline { try await Task.sleep(nanoseconds: deadline - now) }
        try Task.checkCancellation()
    }

    func waitForDeadline() async throws {
        for await start in starts {
            try await Self.sleep(until: start &+ Self.interval)
            return
        }
        throw CancellationError()
    }

    static func bounded<Value: Sendable>(
        onStart: @escaping @Sendable (UInt64) -> Void,
        mayStart: @escaping @Sendable () -> Bool,
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let attempt = Self()
        return try await withThrowingTaskGroup(of: Value.self) { tasks in
            tasks.addTask {
                defer { attempt.finish() }
                return try await HTTPRouteTiming.$current.withValue(attempt.timing(onStart: onStart, mayStart: mayStart), operation: operation)
            }
            tasks.addTask {
                try await attempt.waitForDeadline()
                throw URLError(.timedOut)
            }
            defer { tasks.cancelAll() }
            // A pre-send failure can close the start stream before the request
            // result is delivered. Preserve the actual request error.
            do {
                guard let value = try await tasks.next() else { throw CancellationError() }
                return value
            } catch is CancellationError where !Task.isCancelled {
                guard let value = try await tasks.next() else { throw CancellationError() }
                return value
            }
        }
    }
}

@MainActor
final class IMRouteV5Coordinator {
    private struct Round {
        let id: UUID
        let cancel: () -> Void
        let wait: () async -> Void
    }
    private struct Backoff {
        let configuration: String
        let failures: Int
        let deadline: UInt64
    }
    private enum Outcome<Value: Sendable>: Sendable {
        case rejected
        case validated(URL, Value)
    }

    private let store: IMRuntimeRouteStore
    private let monitor: NWPathMonitor?
    private let networkOverride: (@MainActor @Sendable () -> Bool)?
    private var previousPath: NWPath?
    private var generation: UInt64 = 0
    private var rounds: [IMRouteV5Scope: Round] = [:]
    private var openingReads: [IMRouteV5Scope: (id: UUID, task: Task<Void, Never>)] = [:]
    private var backoff: [IMRouteV5Scope: Backoff] = [:]
    private(set) var session: IMAPIContext?

    init(store: IMRuntimeRouteStore, networkOverride: (@MainActor @Sendable () -> Bool)?) {
        self.store = store
        self.networkOverride = networkOverride
        monitor = networkOverride == nil ? NWPathMonitor() : nil
        monitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.updateNetwork(path) }
        }
        monitor?.start(queue: DispatchQueue(label: "wenxintong.http-route.network"))
    }

    deinit { monitor?.cancel() }

    private func updateNetwork(_ path: NWPath) {
        guard previousPath != path else { return }
        let hadPath = previousPath != nil
        previousPath = path
        guard hadPath else { return }
        generation &+= 1
        invalidate { _ in true }
    }

    var networkGeneration: UInt64 { generation }
    var networkUsable: Bool { networkOverride?() ?? (previousPath?.status == .satisfied) }

    func updateSession(_ context: IMAPIContext) {
        if session?.authSessionFence != context.authSessionFence {
            invalidate(resetBackoff: false) { _ in true }
        }
        session = context
    }

    func invalidate(resetBackoff: Bool = true, where matches: (IMRouteV5Scope) -> Bool) {
        for scope in Array(rounds.keys) where matches(scope) {
            rounds.removeValue(forKey: scope)?.cancel()
        }
        for scope in Array(openingReads.keys) where matches(scope) {
            openingReads.removeValue(forKey: scope)?.task.cancel()
        }
        if resetBackoff { backoff = backoff.filter { !matches($0.key) } }
    }

    func scheduleOpeningRead(scope: IMRouteV5Scope, operation: @escaping @MainActor @Sendable () async -> Void) {
        guard openingReads[scope] == nil else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            if self?.openingReads[scope]?.id == id { self?.openingReads.removeValue(forKey: scope) }
        }
        openingReads[scope] = (id, task)
    }

    func selected(in scope: IMRouteV5Scope, authorized: [URL]) -> URL? {
        store.lastSuccessfulRoute(scope, in: authorized) ?? authorized.first
    }

    func confirmed(_ endpoint: URL, scope: IMRouteV5Scope) {
        store.recordSuccessfulRoute(endpoint, in: scope)
        rounds.removeValue(forKey: scope)?.cancel()
        backoff.removeValue(forKey: scope)
    }

    private func canProbe(_ scope: IMRouteV5Scope, roundID: UUID, networkGeneration: UInt64) -> Bool {
        rounds[scope]?.id == roundID && generation == networkGeneration && networkUsable
    }

    func race<Value: Sendable>(
        scope: IMRouteV5Scope,
        configuration: String,
        networkGeneration: UInt64,
        candidates: [URL],
        trigger: IMRouteV5Attempt,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        probe: @escaping @MainActor @Sendable (URL) async throws -> Value,
        commit: @escaping @MainActor @Sendable (URL, Value) throws -> Bool
    ) async throws -> Value? {
        guard !Task.isCancelled, networkUsable, generation == networkGeneration, isCurrent(),
              !candidates.isEmpty else { return nil }
        if let running = rounds[scope] {
            await running.wait()
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let previous = backoff[scope].flatMap { $0.configuration == configuration ? $0 : nil }
        guard (previous?.deadline ?? 0) <= now else { return nil }
        let id = UUID()
        let round = Task { @MainActor in
            try await withThrowingTaskGroup(of: Outcome<Value>.self) { tasks in
                var nextIndex = 0
                var inFlight = 0
                var nextLaunch = DispatchTime.now().uptimeNanoseconds
                defer { tasks.cancelAll() }
                while !Task.isCancelled {
                    while inFlight < 3, nextIndex < candidates.count {
                        let candidate = candidates[nextIndex]
                        let launch = max(nextLaunch, DispatchTime.now().uptimeNanoseconds)
                        nextLaunch = launch &+ 250_000_000
                        nextIndex += 1
                        inFlight += 1
                        tasks.addTask {
                            do {
                                try await IMRouteV5Attempt.sleep(until: launch)
                                guard await self.canProbe(scope, roundID: id, networkGeneration: networkGeneration),
                                      await isCurrent() else { return .rejected }
                                let value = try await IMRouteV5Attempt.bounded(onStart: {
                                    trigger.recordAlternativeStart($0, service: scope.service)
                                }, mayStart: { trigger.canRace }) { try await probe(candidate) }
                                return .validated(candidate, value)
                            } catch {
                                return .rejected
                            }
                        }
                    }
                    guard let outcome = try await tasks.next() else { break }
                    inFlight -= 1
                    guard !Task.isCancelled, self.canProbe(scope, roundID: id, networkGeneration: networkGeneration),
                          isCurrent() else { return nil as Value? }
                    if case let .validated(endpoint, value) = outcome,
                       try trigger.commitWhileSilent({ try commit(endpoint, value) }) {
                        trigger.recordValidation(service: scope.service)
                        self.backoff.removeValue(forKey: scope)
                        return value
                    }
                }
                if !Task.isCancelled, self.rounds[scope]?.id == id, self.generation == networkGeneration, isCurrent() {
                    let count = min((previous?.failures ?? 0) + 1, 3)
                    let seconds: [UInt64] = [30, 120, 600]
                    self.backoff[scope] = Backoff(configuration: configuration, failures: count,
                        deadline: DispatchTime.now().uptimeNanoseconds &+ seconds[count - 1] * 1_000_000_000)
                }
                return nil
            }
        }
        rounds[scope] = Round(id: id, cancel: { round.cancel() }, wait: { _ = try? await round.value })
        defer {
            if rounds[scope]?.id == id { rounds.removeValue(forKey: scope) }
        }
        return try await withTaskCancellationHandler {
            try await round.value
        } onCancel: {
            round.cancel()
        }
    }
}
// WDT_IOS1_HTTP_ROUTE_V5_20261113_END

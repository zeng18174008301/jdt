import CryptoKit
import Foundation
import Network

struct RealtimeConnectionRequest: Sendable {
    let url: URL
    let token: String
    let webSocketDialMetadata: RealtimeWebSocketDialMetadata?
    let quicRequest: RealtimeQUICConnectionRequest?

    init(
        url: URL,
        token: String,
        webSocketDialMetadata: RealtimeWebSocketDialMetadata? = nil,
        quicRequest: RealtimeQUICConnectionRequest? = nil
    ) {
        self.url = RealtimeEndpointURLSanitizer.canonicalIMWebSocketURLRemovingCredentials(from: url)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.webSocketDialMetadata = webSocketDialMetadata
        self.quicRequest = quicRequest
    }
}

struct RealtimeWebSocketDialMetadata: Sendable, Equatable {
    let dialHost: String
    let port: UInt16
    let tlsServerName: String
    let httpHost: String

    init?(dialHost: String, port: Int, tlsServerName: String, httpHost: String) {
        guard let normalizedDialHost = RealtimeEndpointAddressValidator.normalizedIPLiteral(dialHost) else {
            return nil
        }
        let normalizedTLSServerName = tlsServerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedHTTPHost = httpHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let port = UInt16(exactly: port),
              RealtimeEndpointAddressValidator.isDomainName(normalizedTLSServerName),
              RealtimeEndpointAddressValidator.isDomainName(normalizedHTTPHost) else {
            return nil
        }
        self.dialHost = normalizedDialHost
        self.port = port
        self.tlsServerName = normalizedTLSServerName
        self.httpHost = normalizedHTTPHost
    }
}

@MainActor
protocol RealtimeTransporting: AnyObject, Sendable {
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)? { get set }
    var canReconnect: (@MainActor () -> Bool)? { get set }
    var onConnectionUnavailable: (@MainActor () -> Void)? { get set }
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)? { get set }
    var onConnected: (@MainActor () -> Void)? { get set }
    var onDisconnected: (@MainActor () -> Void)? { get set }
    var onReconnectAttempt: (@MainActor () -> Void)? { get set }
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)? { get set }
    var isConnected: Bool { get }

    func start(url: URL, token: String)
    func start(request: RealtimeConnectionRequest)
    func disconnect(shouldReconnect: Bool)
    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String)
}

extension RealtimeTransporting {
    func start(request: RealtimeConnectionRequest) {
        start(url: request.url, token: request.token)
    }
}

enum RealtimeNetworkPathStatus: Sendable, Equatable {
    case satisfied
    case unsatisfied
}

private enum RealtimeActiveTransportKind {
    case webSocket
    case quic
}

enum RealtimeConnectionState: String, Equatable, Sendable {
    case idle
    case dialing
    case awaitingAck = "awaiting_ack"
    case connected
    case backoff
}

/// Diagnostic values are closed labels only; never retain a request or raw error.
struct RealtimeConnectionDiagnostic: Equatable, Sendable {
    enum Stage: String, Sendable { case admission = "ADMISSION", start = "START", auth = "AUTH", socket = "SOCKET", server = "SERVER", response = "RESPONSE" }
    enum Result: Equatable, Sendable {
        case started, acknowledged, stopRequested, sceneInactive, notAuthenticated, missingSession
        case reconnectNotAllowed, routeUnavailable, ownerBusy, alreadyActive, serverRejected, unauthorized, forbidden
        case acknowledgementTimeout, generationDeadline, frameEncodingFailed, responseObserved
        case failure(SyncFailureDiagnostic.Failure)

        var label: String {
            switch self {
            case .started: return "STARTED"
            case .acknowledged: return "ACKNOWLEDGED"
            case .stopRequested: return "STOP_REQUESTED"
            case .sceneInactive: return "SCENE_INACTIVE"
            case .notAuthenticated: return "NOT_AUTHENTICATED"
            case .missingSession: return "MISSING_SESSION"
            case .reconnectNotAllowed: return "RECONNECT_NOT_ALLOWED"
            case .routeUnavailable: return "ROUTE_UNAVAILABLE"
            case .ownerBusy: return "OWNER_BUSY"
            case .alreadyActive: return "ALREADY_ACTIVE"
            case .serverRejected: return "SERVER_REJECTED"
            case .unauthorized: return "UNAUTHORIZED"
            case .forbidden: return "FORBIDDEN"
            case .acknowledgementTimeout: return "ACK_TIMEOUT"
            case .generationDeadline: return "GENERATION_DEADLINE"
            case .frameEncodingFailed: return "FRAME_ENCODING_FAILED"
            case .responseObserved: return "RESPONSE_OBSERVED"
            case .failure(let code): return code.rawValue
            }
        }

        static func socketFailure(_ error: Error) -> Self {
            if let error = error as? RealtimeClientError {
                switch error {
                case .acknowledgementTimeout: return .acknowledgementTimeout
                case .generationDeadlineExceeded: return .generationDeadline
                case .connectFrameEncodingFailed: return .frameEncodingFailed
                }
            }
            return .failure(SyncFailureDiagnostic.Failure(error: error))
        }

        static func serverError(_ code: String) -> Self {
            switch code {
            case "unauthorized": return .unauthorized
            case "forbidden": return .forbidden
            default: return .serverRejected
            }
        }
    }
    enum Transport: String, Sendable { case none = "NONE", webSocket = "WEBSOCKET", quic = "QUIC" }
    /// Exact allowlist, not a sanitizer for arbitrary server text. Aliases remain distinct.
    enum ServerCode: String, CaseIterable, Sendable {
        case none = "NONE", missing = "MISSING", unknown = "UNKNOWN"
        case unauthorized = "UNAUTHORIZED", forbidden = "FORBIDDEN"
        case connectFailed = "CONNECT_FAILED", connectRequired = "CONNECT_REQUIRED"
        case notFriends = "NOT_FRIENDS", friendshipRequired = "FRIENDSHIP_REQUIRED"
        case securityBlocked = "SECURITY_BLOCKED"
        case deviceKicked = "DEVICE_KICKED", deviceRevoked = "DEVICE_REVOKED", deviceDisabled = "DEVICE_DISABLED", deviceBanned = "DEVICE_BANNED", deviceBindingViolation = "DEVICE_BINDING_VIOLATION"
        case registeredUserQuotaExceeded = "REGISTERED_USER_QUOTA_EXCEEDED"
        case onlineQuotaExceeded = "ONLINE_QUOTA_EXCEEDED"
        case onlineQuotaServiceUnavailable = "ONLINE_QUOTA_SERVICE_UNAVAILABLE"
        case groupMemberQuotaExceeded = "GROUP_MEMBER_QUOTA_EXCEEDED"
        case workspaceSwitchDisabled = "WORKSPACE_SWITCH_DISABLED"
        case accountLocked = "ACCOUNT_LOCKED", accountBlocked = "ACCOUNT_BLOCKED", accountDisabled = "ACCOUNT_DISABLED"
        case deviceBlocked = "DEVICE_BLOCKED", ipLoginBlocked = "IP_LOGIN_BLOCKED", ipNotAllowed = "IP_NOT_ALLOWED", ipBlocked = "IP_BLOCKED"
        case accountPasswordSyncFailed = "ACCOUNT_PASSWORD_SYNC_FAILED", slideCaptchaRequired = "SLIDE_CAPTCHA_REQUIRED", invalidCredentials = "INVALID_CREDENTIALS"
        case tenantBlocked = "TENANT_BLOCKED", securityPolicyDenied = "SECURITY_POLICY_DENIED"
        case tenantServiceStopped = "TENANT_SERVICE_STOPPED", tenantDisabled = "TENANT_DISABLED"
        case workspaceSessionUnavailable = "WORKSPACE_SESSION_UNAVAILABLE", tenantServiceUnavailable = "TENANT_SERVICE_UNAVAILABLE"
        case appNotFound = "APP_NOT_FOUND", accessDiscoveryAppUnavailable = "ACCESS_DISCOVERY_APP_UNAVAILABLE", defaultWorkspaceUnavailable = "DEFAULT_WORKSPACE_UNAVAILABLE"
        case tenantMemberNotFound = "TENANT_MEMBER_NOT_FOUND", workspaceNotFound = "WORKSPACE_NOT_FOUND", tenantNotFound = "TENANT_NOT_FOUND", appTenantNotBound = "APP_TENANT_NOT_BOUND"
        case workspaceIdentityUnlinked = "WORKSPACE_IDENTITY_UNLINKED"
        case memberProjectionSyncing = "MEMBER_PROJECTION_SYNCING", memberProjectionPending = "MEMBER_PROJECTION_PENDING", memberProjectionMissing = "MEMBER_PROJECTION_MISSING"
        case memberProjectionStale = "MEMBER_PROJECTION_STALE", memberProjectionSync = "MEMBER_PROJECTION_SYNC"
        case memberProjectionFailed = "MEMBER_PROJECTION_FAILED", memberProjectionConflict = "MEMBER_PROJECTION_CONFLICT", memberProjectionRejected = "MEMBER_PROJECTION_REJECTED"
        case tenantMemberDisabled = "TENANT_MEMBER_DISABLED", memberDisabled = "MEMBER_DISABLED"

        init(code: String) {
            let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !normalized.isEmpty else { self = .missing; return }
            self = Self(rawValue: normalized).flatMap { [.none, .missing, .unknown].contains($0) ? nil : $0 } ?? .unknown
        }

        static func from(_ envelope: RealtimeEnvelope) -> Self {
            guard envelope.type == "error" else { return .none }
            var payload = envelope.payload
            // Same container/key precedence as AppState.realtimeErrorString.
            for key in ["error", "data", "payload"] {
                for (key, value) in envelope.payload[key]?.objectValue ?? [:] where payload[key] == nil {
                    payload[key] = value
                }
            }
            let code = ["code", "reason_code", "reasonCode"].compactMap {
                payload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first { !$0.isEmpty } ?? ""
            return Self(code: code)
        }
    }
    enum Operation: String, Sendable { case connect = "CONNECT", subscribeChannel = "SUBSCRIBE_CHANNEL", ping = "PING", unproven = "UNPROVEN" }
    enum Correlation: String, Sendable { case matched = "MATCHED", unmatched = "UNMATCHED", asyncOrNoID = "ASYNC_OR_NO_ID", unproven = "UNPROVEN" }
    enum ScopeMatch: String, Sendable { case current = "CURRENT", stale = "STALE", unproven = "UNPROVEN" }
    enum Handling: String, Sendable {
        case unproven = "UNPROVEN", notDelivered = "NOT_DELIVERED", noHandler = "NO_APP_HANDLER"
        case connectionStateRejected = "CONNECTION_STATE_REJECTED", requestRejected = "ACK_REQUEST_REJECTED", duplicateRejected = "DUPLICATE_REJECTED"
        case staleConnectionRejected = "STALE_CONNECTION_REJECTED"
        case acknowledged = "ACK_ACCEPTED", pongAccepted = "PONG_ACCEPTED", subscriptionAccepted = "SUBSCRIPTION_ACCEPTED"
        case appCallbackReturned = "APP_CALLBACK_RETURNED", appIgnored = "APP_IGNORED"
        case appAuthRejected = "APP_AUTH_REJECTED", appScopeRejected = "APP_SCOPE_REJECTED", messageQueued = "MESSAGE_QUEUED", fallbackScheduled = "FALLBACK_SCHEDULED"
        case deviceRevoked = "DEVICE_REVOKED_HANDLED", screenshotIgnored = "SCREENSHOT_MODE_IGNORED"
        case notFriendsHandled = "NOT_FRIENDS_HANDLED", securityBlockedHandled = "SECURITY_BLOCKED_HANDLED"
        case quotaDisconnected = "QUOTA_DISCONNECTED", workspaceDisconnected = "WORKSPACE_DISCONNECTED", workspaceSelectionForced = "WORKSPACE_SELECTION_FORCED"
        case authDisconnected = "AUTH_DISCONNECTED", errorUnhandled = "ERROR_UNHANDLED"
    }
    let generation: UInt64
    let stage: Stage
    var result: Result
    let transport: Transport
    /// Monotonic time since this connection generation started; admission is zero.
    let elapsedMS: UInt64
    var serverCode: ServerCode = .none
    var handlingCode: ServerCode = .none
    var operation: Operation = .unproven
    var correlation: Correlation = .unproven
    var scopeMatch: ScopeMatch = .unproven
    var handling: Handling = .unproven
    /// Matched generation/leg at receipt, not a claim that the connection survives handling.
    var currentAtReceipt: Bool = true
    var stateAfter: RealtimeConnectionState? = nil
    var scopeAfter: ScopeMatch = .unproven
    var generationAfter: UInt64? = nil
    var isFailure: Bool {
        switch result {
        case .serverRejected, .unauthorized, .forbidden, .acknowledgementTimeout,
             .generationDeadline, .frameEncodingFailed, .failure: return true
        default: return false
        }
    }
    var summary: String {
        "connection_result generation=\(generation) stage=\(stage.rawValue) result=\(result.label) transport=\(transport.rawValue) elapsed_ms=\(elapsedMS) code=\(serverCode.rawValue) handled_code=\(handlingCode.rawValue) operation=\(operation.rawValue) correlation=\(correlation.rawValue) scope_at_receipt=\(scopeMatch.rawValue) handling=\(handling.rawValue) current_at_receipt=\(currentAtReceipt) state_after=\(stateAfter?.rawValue ?? "UNPROVEN") scope_after=\(scopeAfter.rawValue) generation_after=\(generationAfter.map(String.init) ?? "UNPROVEN")"
    }
}

/// Only request IDs already emitted by this client are retained, memory-only, for one leg.
/// This is a bounded diagnostic index; it never participates in wire/ACK/retry decisions.
struct RealtimeDiagnosticRequestIndex {
    static let capacity = 32
    private var requests: [(String, RealtimeConnectionDiagnostic.Operation)] = []
    var count: Int { requests.count }
    mutating func record(_ requestID: String, operation: RealtimeConnectionDiagnostic.Operation) {
        guard !requestID.isEmpty, requestID.utf8.count <= 256 else { return }
        if let index = requests.firstIndex(where: { $0.0 == requestID }) {
            if requests[index].1 != operation { requests[index].1 = .unproven }
            return
        }
        if requests.count == Self.capacity { requests.removeFirst() }
        requests.append((requestID, operation))
    }
    mutating func reset() { requests.removeAll(keepingCapacity: true) }
    func lookup(_ requestID: String?) -> (RealtimeConnectionDiagnostic.Operation, RealtimeConnectionDiagnostic.Correlation) {
        guard let requestID, !requestID.isEmpty else { return (.unproven, .asyncOrNoID) }
        guard let operation = requests.first(where: { $0.0 == requestID })?.1 else { return (.unproven, .unmatched) }
        return (operation, operation == .unproven ? .unproven : .matched)
    }
}

/// Shared only for the synchronous delivery callback; no envelope, identity or raw error retained.
@MainActor
final class RealtimeEnvelopeDiagnosticObservation {
    var event: RealtimeConnectionDiagnostic
    let scopeEpoch: UInt64?
    init(event: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        self.event = event
        self.scopeEpoch = scopeEpoch
    }
}

enum RealtimeClientError: Error, Equatable {
    case acknowledgementTimeout(transport: String)
    case connectFrameEncodingFailed
    case generationDeadlineExceeded
}

struct RealtimeBatchExpansionResult {
    let frames: [RealtimeEnvelope]
    let visitedElements: Int
    let malformedElements: Int
    let droppedForDepth: Int
    let droppedForLimit: Int

    var didDropInput: Bool {
        malformedElements > 0 || droppedForDepth > 0 || droppedForLimit > 0
    }
}

enum RealtimeBatchExpander {
    static let maximumDepth = 16
    static let maximumFrames = 256
    static let maximumElements = 512
    static let maximumWireBytes = 1_048_576

    static func acceptsWirePayload(byteCount: Int) -> Bool {
        byteCount >= 0 && byteCount <= maximumWireBytes
    }

    private struct WorkItem {
        let envelope: RealtimeEnvelope
        let depth: Int
    }

    static func expand(_ root: RealtimeEnvelope) -> RealtimeBatchExpansionResult {
        var stack = [WorkItem(envelope: root, depth: 0)]
        var frames: [RealtimeEnvelope] = []
        var visitedElements = 0
        var malformedElements = 0
        var droppedForDepth = 0
        var droppedForLimit = 0

        while let item = stack.popLast() {
            let type = item.envelope.type
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard type == "batch" else {
                if frames.count < maximumFrames {
                    frames.append(item.envelope)
                } else {
                    droppedForLimit += 1
                }
                continue
            }
            guard case .array(let nestedFrames)? = item.envelope.payload["frames"] else {
                malformedElements += 1
                continue
            }
            guard item.depth < maximumDepth else {
                droppedForDepth += nestedFrames.count
                continue
            }
            let remainingElementBudget = max(0, maximumElements - visitedElements)
            let acceptedCount = min(nestedFrames.count, remainingElementBudget)
            if acceptedCount < nestedFrames.count {
                droppedForLimit += nestedFrames.count - acceptedCount
            }
            visitedElements += acceptedCount
            var accepted: [WorkItem] = []
            accepted.reserveCapacity(acceptedCount)
            for frame in nestedFrames.prefix(acceptedCount) {
                guard case .object(let object) = frame else {
                    malformedElements += 1
                    continue
                }
                let nestedType = (object["type"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nestedType.isEmpty else {
                    malformedElements += 1
                    continue
                }
                let requestID = object["request_id"]?.stringValue
                    ?? object["requestID"]?.stringValue
                let payload = object["payload"]?.objectValue
                    ?? object["data"]?.objectValue
                    ?? [:]
                accepted.append(WorkItem(
                    envelope: RealtimeEnvelope(
                        type: nestedType,
                        requestID: requestID,
                        payload: payload
                    ),
                    depth: item.depth + 1
                ))
            }
            stack.append(contentsOf: accepted.reversed())
        }

        return RealtimeBatchExpansionResult(
            frames: frames,
            visitedElements: visitedElements,
            malformedElements: malformedElements,
            droppedForDepth: droppedForDepth,
            droppedForLimit: droppedForLimit
        )
    }
}

protocol RealtimeRetryAfterProviding: Error {
    var realtimeRetryAfter: TimeInterval? { get }
}

protocol RealtimeMonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(untilNanoseconds deadlineNanoseconds: UInt64) async throws
}

struct SystemRealtimeMonotonicClock: RealtimeMonotonicClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(untilNanoseconds deadlineNanoseconds: UInt64) async throws {
        while true {
            let now = nowNanoseconds()
            guard deadlineNanoseconds > now else { return }
            try await Task.sleep(nanoseconds: deadlineNanoseconds - now)
        }
    }
}

protocol RealtimeNetworkMonitoring: AnyObject, Sendable {
    func start(pathUpdateHandler: @escaping @Sendable (RealtimeNetworkPathStatus) -> Void)
    func cancel()
}

final class NWPathRealtimeNetworkMonitor: RealtimeNetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.jianhuitong.realtime.path-monitor")

    func start(pathUpdateHandler: @escaping @Sendable (RealtimeNetworkPathStatus) -> Void) {
        monitor.pathUpdateHandler = { path in
            pathUpdateHandler(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

@MainActor
final class RealtimeClient: RealtimeTransporting {
    var connectionRequestProvider: (@MainActor () -> RealtimeConnectionRequest?)?
    var canReconnect: (@MainActor () -> Bool)?
    var onConnectionUnavailable: (@MainActor () -> Void)?
    var onConnectionStateChanged: (@MainActor (Bool) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnectAttempt: (@MainActor () -> Void)?
    var onEnvelope: (@MainActor (RealtimeEnvelope) -> Void)?
    var onReconnectScheduled: (@MainActor (TimeInterval) -> Void)?
    var onQUICFallbackToWebSocket: (@MainActor (Error) -> Void)?
    var onRouteFailure: (@MainActor (Error) -> Void)?
    var diagnosticScopeProvider: (@MainActor () -> UInt64?)?
    var onDiagnostic: (@MainActor (RealtimeConnectionDiagnostic, UInt64?) -> Void)?
    private var diagnosticScopeEpoch: UInt64?
    private var diagnosticStartedAt: UInt64?
    private var diagnosticRequests = RealtimeDiagnosticRequestIndex()
    private(set) var currentEnvelopeDiagnostic: RealtimeEnvelopeDiagnosticObservation?

    func recordAdmissionDiagnostic(_ result: RealtimeConnectionDiagnostic.Result) {
        recordDiagnostic(.admission, result: result, elapsedMS: 0)
    }

    private func recordDiagnostic(
        _ stage: RealtimeConnectionDiagnostic.Stage,
        result: RealtimeConnectionDiagnostic.Result,
        elapsedMS: UInt64? = nil
    ) {
        let event = makeDiagnostic(stage, result: result, elapsedMS: elapsedMS)
        let scopeEpoch = stage == .admission ? diagnosticScopeProvider?() : diagnosticScopeEpoch
        publishDiagnostic(event, scopeEpoch: scopeEpoch)
    }

    private func makeDiagnostic(
        _ stage: RealtimeConnectionDiagnostic.Stage,
        result: RealtimeConnectionDiagnostic.Result,
        elapsedMS: UInt64? = nil
    ) -> RealtimeConnectionDiagnostic {
        let now = monotonicClock.nowNanoseconds()
        let start = diagnosticStartedAt ?? now
        var event = RealtimeConnectionDiagnostic(
            generation: connectionGeneration, stage: stage, result: result,
            transport: activeTransportKind.map { $0 == .webSocket ? .webSocket : .quic } ?? .none,
            elapsedMS: elapsedMS ?? (now >= start ? (now - start) / 1_000_000 : 0)
        )
        let scopeEpoch = stage == .admission ? diagnosticScopeProvider?() : diagnosticScopeEpoch
        if let scopeEpoch, let current = diagnosticScopeProvider?() {
            event.scopeMatch = scopeEpoch == current ? .current : .stale
        }
        return event
    }

    private func finishDiagnostic(_ original: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        var event = original
        event.stateAfter = connectionState
        event.generationAfter = connectionGeneration
        if let scopeEpoch, let current = diagnosticScopeProvider?() {
            event.scopeAfter = scopeEpoch == current ? .current : .stale
        }
        publishDiagnostic(event, scopeEpoch: scopeEpoch)
    }

    private func publishDiagnostic(_ event: RealtimeConnectionDiagnostic, scopeEpoch: UInt64?) {
        SyncFailureDiagnostic.persistConnection(event)
        onDiagnostic?(event, scopeEpoch)
    }

    private var socket: RealtimeWebSocketTasking?
    private var quicConnection: RealtimeQUICConnectioning?
    private var quicConnectTask: Task<Void, Never>?
    private var quicConnectCancellation: (@Sendable () -> Void)?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var acknowledgementDeadlineTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var awaitingPong = false
    private var missedPongCount = 0
    private var lastNetworkPathStatus: RealtimeNetworkPathStatus?
    private var subscribedChannels: Set<String> = []
    private var activeTransportKind: RealtimeActiveTransportKind?
    private var activeRequest: RealtimeConnectionRequest?
    private var activeToken: String?
    private var activeLegID: UInt64 = 0
    private var activeConnectRequestID: String?
    private var generationDeadlineNanoseconds: UInt64?
    private var didFallbackToWebSocket = false
    private let transport: RealtimeWebSocketTransporting
    private let quicTransport: RealtimeQUICTransporting
    private let quicConfiguration: RealtimeQUICConfiguration
    private let wireCodec: any WireCodec
    private let heartbeatIntervalNanoseconds: UInt64
    private let acknowledgementTimeoutNanoseconds: UInt64
    private let generationTimeoutNanoseconds: UInt64 = 8_000_000_000
    private let maximumMissedPongs: Int
    private let reconnectCaps: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
    private let reconnectDelayScale: Double
    private let reconnectJitterProvider: @MainActor () -> Double
    private let requestIDProvider: @MainActor (String) -> String
    private let monotonicClock: any RealtimeMonotonicClock
    private let networkMonitor: RealtimeNetworkMonitoring?
    private let realtimeBatchCapabilityEnabled: Bool
	private let continuity: IMRuntimeWebSocketContinuity
	private let continuityOwner = UUID().uuidString

    init(
        transport: RealtimeWebSocketTransporting = URLSessionRealtimeTransport(),
        quicTransport: RealtimeQUICTransporting = NWRealtimeQUICTransport(),
        quicConfiguration: RealtimeQUICConfiguration = RealtimeQUICConfiguration.load(),
        wireCodec: any WireCodec = JSONWireCodec(),
        heartbeatIntervalNanoseconds: UInt64 = 25_000_000_000,
        acknowledgementTimeoutNanoseconds: UInt64 = 5_000_000_000,
        maximumMissedPongs: Int = 2,
        reconnectDelayScale: Double = 1,
        reconnectJitterProvider: @escaping @MainActor () -> Double = { Double.random(in: 0..<1) },
        requestIDProvider: @escaping @MainActor (String) -> String = { type in
            "\(type)-\(UUID().uuidString)"
        },
        monotonicClock: any RealtimeMonotonicClock = SystemRealtimeMonotonicClock(),
        networkMonitorFactory: (() -> RealtimeNetworkMonitoring?)? = { NWPathRealtimeNetworkMonitor() },
		realtimeBatchCapabilityEnabled: Bool = false,
		continuity: IMRuntimeWebSocketContinuity = .shared
    ) {
        self.transport = transport
        self.quicTransport = quicTransport
        self.quicConfiguration = quicConfiguration
        self.wireCodec = wireCodec
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
        self.acknowledgementTimeoutNanoseconds = min(
            acknowledgementTimeoutNanoseconds,
            5_000_000_000
        )
        self.maximumMissedPongs = max(1, maximumMissedPongs)
        self.reconnectDelayScale = max(0, reconnectDelayScale)
        self.reconnectJitterProvider = reconnectJitterProvider
        self.requestIDProvider = requestIDProvider
		self.monotonicClock = monotonicClock
		self.continuity = continuity
        self.networkMonitor = networkMonitorFactory?()
        self.realtimeBatchCapabilityEnabled = realtimeBatchCapabilityEnabled
        self.networkMonitor?.start { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathStatus(status)
            }
        }
    }

    deinit {
        networkMonitor?.cancel()
		continuity.release(continuityOwner)
    }

    private(set) var connectionGeneration: UInt64 = 0

    private(set) var connectionState: RealtimeConnectionState = .idle {
        didSet {
            let wasConnected = oldValue == .connected
            let isNowConnected = connectionState == .connected
            guard wasConnected != isNowConnected else { return }
            onConnectionStateChanged?(isNowConnected)
        }
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    func start(url: URL, token: String) {
        start(request: RealtimeConnectionRequest(url: url, token: token))
    }

    func disconnect(shouldReconnect: Bool) {
        let diagnostic = makeDiagnostic(.socket, result: .stopRequested)
        let scopeEpoch = diagnosticScopeEpoch
        defer { finishDiagnostic(diagnostic, scopeEpoch: scopeEpoch) }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration &+= 1
        stopActiveLeg()
        activeRequest = nil
        activeToken = nil
		didFallbackToWebSocket = false
		if !shouldReconnect { continuity.release(continuityOwner) }
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String) {
        guard connectionState == .connected else { return }
        let trimmedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannelType = channelType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChannelID.isEmpty, !trimmedChannelType.isEmpty else { return }
        let key = "\(trimmedChannelType)|\(trimmedChannelID)"
        guard !subscribedChannels.contains(key) else { return }
        sendPacket(
            type: "subscribe_channel",
            payload: [
                "tenant_id": tenantID,
                "im_uid": imUID,
                "device_id": deviceID,
                "channel_id": trimmedChannelID,
                "channel_type": trimmedChannelType
            ]
        )
    }

    private func startFromProvider() {
        guard canReconnect?() == true else {
            recordAdmissionDiagnostic(.reconnectNotAllowed)
            transition(to: .idle)
            return
        }
        guard let request = connectionRequestProvider?() else {
            recordAdmissionDiagnostic(.routeUnavailable)
            transition(to: .idle)
            onConnectionUnavailable?()
            return
        }
        let previousGeneration = connectionGeneration
        start(request: request)
        if connectionGeneration != previousGeneration {
            onReconnectAttempt?()
        }
    }

    func start(request: RealtimeConnectionRequest) {
        let request = sanitizedConnectionRequest(request)
        guard !request.token.isEmpty else {
            recordAdmissionDiagnostic(.missingSession)
            return
        }
        guard continuity.acquire(continuityOwner) else {
            recordAdmissionDiagnostic(.ownerBusy)
            return
        }
        if [.dialing, .awaitingAck, .connected].contains(connectionState),
           activeToken == request.token {
            recordAdmissionDiagnostic(.alreadyActive)
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        stopActiveLeg()
        connectionGeneration &+= 1
        // Ownership belongs to the admitted generation, not the scope at callback time.
        diagnosticScopeEpoch = diagnosticScopeProvider?()
        diagnosticStartedAt = monotonicClock.nowNanoseconds()
        generationDeadlineNanoseconds = addingWithoutOverflow(
            generationTimeoutNanoseconds,
            to: monotonicClock.nowNanoseconds()
        )
        activeLegID = 0
        activeRequest = request
        activeToken = request.token
        didFallbackToWebSocket = false
        subscribedChannels.removeAll()

        let generation = connectionGeneration
        let discoveryQUICRequest = quicConfiguration.isEnabled ? request.quicRequest : nil
        if let quicRequest = discoveryQUICRequest ?? quicConfiguration.connectionRequest(token: request.token) {
            startQUIC(request: sanitizedQUICRequest(quicRequest, token: request.token), generation: generation)
        } else {
            startWebSocket(request: request, generation: generation)
        }
    }

    private func startWebSocket(request: RealtimeConnectionRequest, generation: UInt64) {
        guard connectionGeneration == generation,
              socket == nil,
              quicConnection == nil,
              quicConnectTask == nil else {
            return
        }
        activeLegID &+= 1
        let legID = activeLegID
        let connectRequestID = nextRequestID(type: "connect")
        activeConnectRequestID = connectRequestID
        activeTransportKind = .webSocket
        transition(to: .dialing)
        guard scheduleAcknowledgementDeadline(generation: generation, legID: legID, kind: .webSocket) else {
            handleActiveLegFailure(
                RealtimeClientError.generationDeadlineExceeded,
                retryAfter: nil,
                generation: generation,
                legID: legID,
                kind: .webSocket,
                permitsQUICFallback: false
            )
            return
        }

        print("[JHT Realtime] start_ws url=\(Self.redactedEndpointSummary(request.url)) ip_hint=\(request.webSocketDialMetadata != nil)")
        let newSocket = transport.webSocketTask(with: request)
        socket = newSocket
        newSocket.resume()
        recordDiagnostic(.start, result: .started)
        transition(to: .awaitingAck)
        guard sendConnectOverWebSocket(
            token: request.token,
            requestID: connectRequestID,
            socket: newSocket,
            generation: generation,
            legID: legID
        ) else {
            return
        }

        receiveTask = Task { [weak self, weak newSocket] in
            guard let newSocket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await newSocket.receive()
                    await MainActor.run { [weak self] in
                        self?.handle(message, generation: generation, legID: legID)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.handleWebSocketFailure(
                            error,
                            socket: newSocket,
                            generation: generation,
                            legID: legID
                        )
                    }
                    return
                }
            }
        }
    }

    private func startQUIC(request: RealtimeQUICConnectionRequest, generation: UInt64) {
        guard connectionGeneration == generation else { return }
        activeLegID &+= 1
        let legID = activeLegID
        activeConnectRequestID = nextRequestID(type: "connect")
        activeTransportKind = .quic
        transition(to: .dialing)
        guard scheduleAcknowledgementDeadline(generation: generation, legID: legID, kind: .quic) else {
            handleActiveLegFailure(
                RealtimeClientError.generationDeadlineExceeded,
                retryAfter: nil,
                generation: generation,
                legID: legID,
                kind: .quic,
                permitsQUICFallback: false
            )
            return
        }
        print("[JHT Realtime] start_quic host=\(request.host) path=\(request.path)")
        let connectOperation: @Sendable () async throws -> RealtimeQUICConnectioning
        if let attemptProvider = quicTransport as? RealtimeQUICConnectAttemptProviding {
            let attempt = attemptProvider.makeConnectAttempt(request)
            quicConnectCancellation = { attempt.cancel() }
            connectOperation = { try await attempt.connect() }
        } else {
            let quicTransport = self.quicTransport
            quicConnectCancellation = nil
            connectOperation = { try await quicTransport.connect(request) }
        }
        quicConnectTask = Task { [weak self] in
            guard let self else { return }
            if self.isCurrentLeg(generation: generation, legID: legID, kind: .quic) {
                self.recordDiagnostic(.start, result: .started)
            }
            do {
                let connection = try await connectOperation()
                guard !Task.isCancelled else {
                    connection.cancel()
                    return
                }
                await MainActor.run { [weak self] in
                    self?.finishQUICConnection(
                        connection,
                        token: request.token,
                        generation: generation,
                        legID: legID
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.handleQUICFailure(error, connection: nil, generation: generation, legID: legID)
                }
            }
        }
    }

    private func finishQUICConnection(
        _ connection: RealtimeQUICConnectioning,
        token: String,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .quic),
              socket == nil else {
            connection.cancel()
            return
        }
        quicConnectTask = nil
        quicConnectCancellation = nil
        quicConnection = connection
        transition(to: .awaitingAck)
        guard let connectRequestID = activeConnectRequestID,
              let data = packetData(
                type: "connect",
                requestID: connectRequestID,
                payload: connectPayload(token: token)
              ) else {
            handleQUICFailure(
                RealtimeClientError.connectFrameEncodingFailed,
                connection: connection,
                generation: generation,
                legID: legID
            )
            return
        }

        receiveTask = Task { [weak self, weak connection] in
            guard let connection else { return }
            do {
                if self?.isCurrentLeg(generation: generation, legID: legID, kind: .quic) == true {
                    self?.diagnosticRequests.record(connectRequestID, operation: .connect)
                }
                try await connection.sendLine(data)
                await MainActor.run {
                    print("[JHT Realtime] connect_frame_sent transport=quic")
                }
                while !Task.isCancelled {
                    let data = try await connection.receiveLine()
                    await MainActor.run { [weak self] in
                        self?.handle(data, generation: generation, legID: legID)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.handleQUICFailure(
                        error,
                        connection: connection,
                        generation: generation,
                        legID: legID
                    )
                }
            }
        }
    }

    private func fallbackToWebSocketAfterQUICFailure(
        _ error: Error,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .quic),
              !didFallbackToWebSocket,
              let request = activeRequest else {
            return
        }
        didFallbackToWebSocket = true
        acknowledgementDeadlineTask?.cancel()
        acknowledgementDeadlineTask = nil
        let cancelConnect = quicConnectCancellation
        quicConnectCancellation = nil
        cancelConnect?()
        let connectTask = quicConnectTask
        quicConnectTask = nil
        connectTask?.cancel()
        receiveTask?.cancel()
        receiveTask = nil
        quicConnection?.cancel()
        quicConnection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activeConnectRequestID = nil
        activeTransportKind = nil
        resetHeartbeatState()
        transition(to: .dialing)
        onQUICFallbackToWebSocket?(error)
        startWebSocket(request: request, generation: generation)
    }

    private func stopActiveLeg() {
        diagnosticRequests.reset()
        acknowledgementDeadlineTask?.cancel()
        acknowledgementDeadlineTask = nil
        let cancelConnect = quicConnectCancellation
        quicConnectCancellation = nil
        cancelConnect?()
        quicConnectTask?.cancel()
        quicConnectTask = nil
        quicConnection?.cancel()
        quicConnection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        activeTransportKind = nil
        activeConnectRequestID = nil
        generationDeadlineNanoseconds = nil
        subscribedChannels.removeAll()
        resetHeartbeatState()
        transition(to: .idle)
    }

    private func handleWebSocketFailure(
        _ error: Error,
        socket failedSocket: RealtimeWebSocketTasking,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .webSocket),
              socket === failedSocket else {
            return
        }
        handleActiveLegFailure(
            error,
            retryAfter: failedSocket.realtimeRetryAfter,
            generation: generation,
            legID: legID,
            kind: .webSocket
        )
    }

    private func handleQUICFailure(
        _ error: Error,
        connection failedConnection: RealtimeQUICConnectioning?,
        generation: UInt64,
        legID: UInt64
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: .quic) else {
            failedConnection?.cancel()
            return
        }
        if let failedConnection,
           let quicConnection,
           quicConnection !== failedConnection {
            failedConnection.cancel()
            return
        }
        handleActiveLegFailure(
            error,
            retryAfter: nil,
            generation: generation,
            legID: legID,
            kind: .quic
        )
    }

    private func handleActiveLegFailure(
        _ error: Error,
        retryAfter: TimeInterval?,
        generation: UInt64,
        legID: UInt64,
        kind: RealtimeActiveTransportKind,
        permitsQUICFallback: Bool = true
    ) {
        guard isCurrentLeg(generation: generation, legID: legID, kind: kind) else { return }
        let diagnostic = makeDiagnostic(.socket, result: .socketFailure(error))
        let scopeEpoch = diagnosticScopeEpoch
        defer { finishDiagnostic(diagnostic, scopeEpoch: scopeEpoch) }
        if kind == .quic,
           connectionState != .connected,
           !didFallbackToWebSocket,
           permitsQUICFallback,
           hasRemainingGenerationBudget(generation: generation) {
            fallbackToWebSocketAfterQUICFailure(error, generation: generation, legID: legID)
            return
        }

        let retryAfterFloor = retryAfterFloor(error: error, transportValue: retryAfter)
        print("[JHT Realtime] socket_failure transport=\(Self.transportName(kind)) error=\(Self.redactedErrorSummary(error))")
		onRouteFailure?(error)
        connectionGeneration &+= 1
        stopActiveLeg()
        guard canReconnect?() == true else { return }
        onDisconnected?()
        scheduleReconnect(retryAfterFloor: retryAfterFloor)
    }

    private func scheduleReconnect(retryAfterFloor: TimeInterval? = nil) {
        guard reconnectTask == nil, canReconnect?() == true else { return }
        let cap = reconnectCaps[min(reconnectAttempt, reconnectCaps.count - 1)]
        let sample = reconnectJitterProvider()
        let jitterFraction = sample.isFinite ? min(max(sample, 0), 1) : 0
        let jitteredDelay = cap * jitterFraction
        let delaySeconds = max(jitteredDelay, retryAfterFloor ?? 0)
        let delayNanoseconds = reconnectDelayNanoseconds(seconds: delaySeconds)
        reconnectAttempt += 1
        transition(to: .backoff)
        onReconnectScheduled?(delaySeconds)
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.connectionGeneration == generation,
                      self.connectionState == .backoff else {
                    return
                }
                self.reconnectTask = nil
                self.transition(to: .idle)
                self.startFromProvider()
            }
        }
    }

    private func startHeartbeat(generation: UInt64, legID: UInt64) {
        resetHeartbeatState()
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.heartbeatIntervalNanoseconds ?? 25_000_000_000)
                } catch {
                    return
                }
                await MainActor.run { [weak self] in
                    self?.sendHeartbeatPing(generation: generation, legID: legID)
                }
            }
        }
    }

    private func sendHeartbeatPing(generation: UInt64, legID: UInt64) {
        guard connectionGeneration == generation,
              activeLegID == legID,
              connectionState == .connected else {
            return
        }
        if awaitingPong {
            missedPongCount += 1
            if missedPongCount >= maximumMissedPongs {
                let error = RealtimeClientError.acknowledgementTimeout(
                    transport: Self.transportName(activeTransportKind)
                )
                switch activeTransportKind {
                case .webSocket:
                    if let socket {
                        handleWebSocketFailure(error, socket: socket, generation: generation, legID: legID)
                    }
                case .quic:
                    handleQUICFailure(error, connection: quicConnection, generation: generation, legID: legID)
                case nil:
                    break
                }
                return
            }
        }
        awaitingPong = true
        sendPacket(type: "ping", payload: [:])
    }

    private func resetHeartbeatState() {
        awaitingPong = false
        missedPongCount = 0
    }

    private func connectPayload(token: String) -> [String: Any] {
        var payload: [String: Any] = ["token": token]
        if realtimeBatchCapabilityEnabled, activeTransportKind == .webSocket {
            payload["capabilities"] = ["batch"]
        }
        return payload
    }

	private func realtimeEnvelopeDedupeKey(_ envelope: RealtimeEnvelope) -> String? {
		let normalizedType = envelope.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		let canonicalPayload: [String: JSONValue]
		switch normalizedType {
		case "message", "message_push", "send_ack":
			canonicalPayload = envelope.payload["message"]?.objectValue ?? envelope.payload
			let contentType = firstNonemptyValue(canonicalPayload, keys: ["content_type"])
				?? firstNonemptyValue(canonicalPayload["payload"]?.objectValue ?? [:], keys: ["content_type"])
			// RTC records are immutable authorities. Even malformed replays must reach
			// the store so payload/identity conflicts can open a recovery gap. The
			// store also owns exact-repeat unread and acknowledgement idempotency.
			if contentType?.lowercased() == "rtc_call_record" { return nil }
			if let id = firstNonemptyValue(canonicalPayload, keys: ["message_id", "id"]) {
				return "message|\(id)"
			}
		case "conversation_read":
			canonicalPayload = envelope.payload["read_watermark"]?.objectValue ?? envelope.payload
			guard let eventID = firstNonemptyValue(canonicalPayload, keys: ["event_id", "eventId"]) else {
				return nil
			}
			return "conversation_read|\(eventID)"
		case "message_receipt":
			canonicalPayload = envelope.payload["receipt"]?.objectValue ?? envelope.payload
			let fields = ["message_id", "receipt_type", "im_uid", "device_id", "channel_seq", "created_at"]
				.compactMap { canonicalPayload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if !fields.isEmpty { return "message_receipt|" + fields.joined(separator: "|") }
		case "message_extra":
			canonicalPayload = envelope.payload["extra"]?.objectValue ?? envelope.payload
			let fields = ["message_id", "version", "operator_uid", "extra_type", "emoji", "action", "created_at"]
				.compactMap { canonicalPayload[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if !fields.isEmpty { return "message_extra|" + fields.joined(separator: "|") }
		default:
			guard let eventID = firstNonemptyValue(envelope.payload, keys: ["event_id"]) else { return nil }
			return "\(normalizedType)|\(eventID)"
		}
		let object = canonicalPayload.mapValues(\.anyValue)
		guard JSONSerialization.isValidJSONObject(object),
		      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
		let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		return "\(normalizedType)|sha256:\(digest)"
	}

	private func firstNonemptyValue(_ payload: [String: JSONValue], keys: [String]) -> String? {
		for key in keys {
			if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
				return value
			}
		}
		return nil
	}

    private func sendConnectOverWebSocket(
        token: String,
        requestID: String,
        socket: RealtimeWebSocketTasking,
        generation: UInt64,
        legID: UInt64
    ) -> Bool {
        guard let text = packetText(
            type: "connect",
            requestID: requestID,
            payload: connectPayload(token: token)
        ) else {
            handleWebSocketFailure(
                RealtimeClientError.connectFrameEncodingFailed,
                socket: socket,
                generation: generation,
                legID: legID
            )
            return false
        }
        socket.send(.string(text)) { [weak self, weak socket] error in
            guard let error, let socket else { return }
            Task { @MainActor [weak self] in
                self?.handleWebSocketFailure(error, socket: socket, generation: generation, legID: legID)
            }
        }
        diagnosticRequests.record(requestID, operation: .connect)
        print("[JHT Realtime] connect_frame_sent transport=websocket")
        return true
    }

    private func sendPacket(type: String, payload: [String: Any]) {
        let generation = connectionGeneration
        let legID = activeLegID
        let requestID = nextRequestID(type: type)
        switch activeTransportKind {
        case .webSocket:
            guard let socket,
                  let text = packetText(type: type, requestID: requestID, payload: payload) else {
                return
            }
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.handleWebSocketFailure(error, socket: socket, generation: generation, legID: legID)
                }
            }
            recordDiagnosticRequest(requestID, type: type)
        case .quic:
            guard let quicConnection,
                  let data = packetData(type: type, requestID: requestID, payload: payload) else {
                return
            }
            Task { [weak self, weak quicConnection] in
                do {
                    if quicConnection != nil,
                       self?.isCurrentLeg(generation: generation, legID: legID, kind: .quic) == true {
                        self?.recordDiagnosticRequest(requestID, type: type)
                    }
                    try await quicConnection?.sendLine(data)
                } catch {
                    await MainActor.run { [weak self] in
                        self?.handleQUICFailure(
                            error,
                            connection: quicConnection,
                            generation: generation,
                            legID: legID
                        )
                    }
                }
            }
        case nil:
            return
        }
    }

    private func recordDiagnosticRequest(_ requestID: String, type: String) {
        let operation: RealtimeConnectionDiagnostic.Operation
        switch type {
        case "connect": operation = .connect
        case "subscribe_channel": operation = .subscribeChannel
        case "ping": operation = .ping
        default: operation = .unproven
        }
        diagnosticRequests.record(requestID, operation: operation)
    }

    private func packetData(type: String, requestID: String, payload: [String: Any]) -> Data? {
        try? wireCodec.encodeJSONObject([
            "type": type,
            "request_id": requestID,
            "payload": payload
        ])
    }

    private func packetText(type: String, requestID: String, payload: [String: Any]) -> String? {
        guard let data = packetData(type: type, requestID: requestID, payload: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func handle(_ data: Data, generation: UInt64, legID: UInt64) {
        guard RealtimeBatchExpander.acceptsWirePayload(byteCount: data.count) else {
            print("[JHT Realtime] frame_skip reason=wire_limit bytes=\(data.count)")
            return
        }
        guard let envelope = try? wireCodec.decode(RealtimeEnvelope.self, from: data) else { return }
        handle(envelope, generation: generation, legID: legID)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, generation: UInt64, legID: UInt64) {
        let data: Data?
        switch message {
        case .string(let text):
            guard RealtimeBatchExpander.acceptsWirePayload(
                byteCount: text.utf8.count
            ) else {
                print("[JHT Realtime] frame_skip reason=wire_limit")
                return
            }
            data = text.data(using: .utf8)
        case .data(let binary):
            guard RealtimeBatchExpander.acceptsWirePayload(
                byteCount: binary.count
            ) else {
                print("[JHT Realtime] frame_skip reason=wire_limit bytes=\(binary.count)")
                return
            }
            data = binary
        @unknown default:
            data = nil
        }
        guard let data,
              let envelope = try? wireCodec.decode(RealtimeEnvelope.self, from: data) else { return }
        handle(envelope, generation: generation, legID: legID)
    }

    private func handle(_ envelope: RealtimeEnvelope, generation: UInt64, legID: UInt64) {
        guard connectionGeneration == generation,
              activeLegID == legID else {
            recordStaleEnvelopeDiagnostic(envelope, generation: generation)
            return
        }
        if envelope.type == "batch" {
            let expansion = RealtimeBatchExpander.expand(envelope)
            if expansion.didDropInput {
                print(
                    "[JHT Realtime] batch_bounded visited=\(expansion.visitedElements) malformed=\(expansion.malformedElements) depth_drop=\(expansion.droppedForDepth) limit_drop=\(expansion.droppedForLimit)"
                )
            }
            for frame in expansion.frames {
                handleFlattened(frame, generation: generation, legID: legID)
            }
            return
        }
        handleFlattened(envelope, generation: generation, legID: legID)
    }

    private func handleFlattened(
        _ envelope: RealtimeEnvelope,
        generation: UInt64,
        legID: UInt64
    ) {
        guard connectionGeneration == generation,
              activeLegID == legID else {
            recordStaleEnvelopeDiagnostic(envelope, generation: generation)
            return
        }
        let observedTypes = ["error", "connect_ack", "pong", "subscribe_ack", "message", "message_push", "send_ack"]
        let observation: RealtimeEnvelopeDiagnosticObservation?
        if observedTypes.contains(envelope.type) {
            let rawCode = envelope.payload["code"]?.stringValue ?? ""
            let stage: RealtimeConnectionDiagnostic.Stage = envelope.type == "error"
                ? (["unauthorized", "forbidden", "connect_failed", "connect_required"].contains(rawCode) ? .auth : .server)
                : (envelope.type == "connect_ack" ? .auth : .response)
            var event = makeDiagnostic(stage, result: envelope.type == "error" ? .serverError(rawCode) : .responseObserved)
            event.serverCode = .from(envelope)
            (event.operation, event.correlation) = diagnosticRequests.lookup(envelope.requestID)
            event.handling = .notDelivered
            observation = RealtimeEnvelopeDiagnosticObservation(event: event, scopeEpoch: diagnosticScopeEpoch)
        } else {
            observation = nil
        }
        let previousObservation = currentEnvelopeDiagnostic
        currentEnvelopeDiagnostic = observation
        defer {
            currentEnvelopeDiagnostic = previousObservation
            if let observation {
                finishDiagnostic(observation.event, scopeEpoch: observation.scopeEpoch)
            }
        }
        switch envelope.type {
        case "connect_ack":
            guard connectionState == .awaitingAck,
                  let expectedRequestID = activeConnectRequestID,
                  envelope.requestID == expectedRequestID else {
                observation?.event.handling = .requestRejected
                return
            }
            observation?.event.result = .acknowledged
            observation?.event.handling = .acknowledged
            print("[JHT Realtime] connect_ack transport=\(Self.transportName(activeTransportKind))")
            acknowledgementDeadlineTask?.cancel()
            acknowledgementDeadlineTask = nil
            transition(to: .connected)
            reconnectAttempt = 0
            resetHeartbeatState()
            startHeartbeat(generation: generation, legID: legID)
            onConnected?()
        case "pong":
            guard connectionState == .connected else {
                observation?.event.handling = .connectionStateRejected
                return
            }
            resetHeartbeatState()
            observation?.event.handling = .pongAccepted
        case "subscribe_ack":
            guard connectionState == .connected else {
                observation?.event.handling = .connectionStateRejected
                return
            }
            let channelID = envelope.payload["channel_id"]?.stringValue ?? ""
            let channelType = envelope.payload["channel_type"]?.stringValue ?? ""
            if !channelID.isEmpty, !channelType.isEmpty {
                subscribedChannels.insert("\(channelType)|\(channelID)")
            }
            observation?.event.handling = .subscriptionAccepted
        case "batch":
            return
        default:
            guard connectionState == .connected else {
                observation?.event.handling = .connectionStateRejected
                return
            }
			if let dedupeKey = realtimeEnvelopeDedupeKey(envelope),
			   !continuity.accept(messageID: dedupeKey) {
                observation?.event.handling = .duplicateRejected
                return
            }
            observation?.event.handling = onEnvelope == nil ? .noHandler : .appCallbackReturned
            onEnvelope?(envelope)
        }
    }

    private func recordStaleEnvelopeDiagnostic(_ envelope: RealtimeEnvelope, generation: UInt64) {
        guard envelope.type == "error" else { return }
        var event = RealtimeConnectionDiagnostic(generation: generation, stage: .server,
            result: .serverError(envelope.payload["code"]?.stringValue ?? ""), transport: .none, elapsedMS: 0)
        event.serverCode = .from(envelope)
        event.handling = .staleConnectionRejected
        event.currentAtReceipt = false
        // No lookup against the current leg's request IDs or current session.
        publishDiagnostic(event, scopeEpoch: nil)
    }

    private func scheduleAcknowledgementDeadline(
        generation: UInt64,
        legID: UInt64,
        kind: RealtimeActiveTransportKind
    ) -> Bool {
        acknowledgementDeadlineTask?.cancel()
        guard connectionGeneration == generation,
              let generationDeadlineNanoseconds else {
            return false
        }
        let nowNanoseconds = monotonicClock.nowNanoseconds()
        guard generationDeadlineNanoseconds > nowNanoseconds else {
            return false
        }
        let legDeadlineNanoseconds = addingWithoutOverflow(
            acknowledgementTimeoutNanoseconds,
            to: nowNanoseconds
        )
        let effectiveDeadlineNanoseconds = min(legDeadlineNanoseconds, generationDeadlineNanoseconds)
        let exhaustsGenerationBudget = effectiveDeadlineNanoseconds == generationDeadlineNanoseconds
        let monotonicClock = self.monotonicClock
        acknowledgementDeadlineTask = Task { [weak self] in
            do {
                try await monotonicClock.sleep(untilNanoseconds: effectiveDeadlineNanoseconds)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentLeg(generation: generation, legID: legID, kind: kind),
                      self.connectionState != .connected else {
                    return
                }
                let error = RealtimeClientError.acknowledgementTimeout(
                    transport: Self.transportName(kind)
                )
                self.handleActiveLegFailure(
                    exhaustsGenerationBudget
                        ? RealtimeClientError.generationDeadlineExceeded
                        : error,
                    retryAfter: nil,
                    generation: generation,
                    legID: legID,
                    kind: kind,
                    permitsQUICFallback: !exhaustsGenerationBudget
                )
            }
        }
        return true
    }

    private func hasRemainingGenerationBudget(generation: UInt64) -> Bool {
        guard connectionGeneration == generation,
              let generationDeadlineNanoseconds else {
            return false
        }
        return monotonicClock.nowNanoseconds() < generationDeadlineNanoseconds
    }

    private func addingWithoutOverflow(_ interval: UInt64, to instant: UInt64) -> UInt64 {
        let (deadline, overflow) = instant.addingReportingOverflow(interval)
        return overflow ? UInt64.max : deadline
    }

    private func isCurrentLeg(
        generation: UInt64,
        legID: UInt64,
        kind: RealtimeActiveTransportKind
    ) -> Bool {
        connectionGeneration == generation
            && activeLegID == legID
            && activeTransportKind == kind
    }

    private func transition(to state: RealtimeConnectionState) {
        connectionState = state
    }

    private func nextRequestID(type: String) -> String {
        let requestID = requestIDProvider(type).trimmingCharacters(in: .whitespacesAndNewlines)
        return requestID.isEmpty ? "\(type)-\(UUID().uuidString)" : requestID
    }

    private func sanitizedConnectionRequest(_ request: RealtimeConnectionRequest) -> RealtimeConnectionRequest {
        RealtimeConnectionRequest(
            url: request.url,
            token: request.token,
            webSocketDialMetadata: request.webSocketDialMetadata,
            quicRequest: request.quicRequest.map { sanitizedQUICRequest($0, token: request.token) }
        )
    }

    private func sanitizedQUICRequest(
        _ request: RealtimeQUICConnectionRequest,
        token: String
    ) -> RealtimeQUICConnectionRequest {
        let sanitizedPath = RealtimeEndpointURLSanitizer.removingQueryAndFragment(fromPath: request.path)
        return RealtimeQUICConnectionRequest(
            host: request.host,
            dialHost: request.dialHost,
            port: request.port,
            path: sanitizedPath.isEmpty ? "/im/quic" : sanitizedPath,
            token: token,
            alpn: request.alpn,
            tlsServerName: request.tlsServerName,
            connectTimeoutNanoseconds: request.connectTimeoutNanoseconds
        )
    }

    private func retryAfterFloor(error: Error, transportValue: TimeInterval?) -> TimeInterval? {
        let errorValue = (error as? RealtimeRetryAfterProviding)?.realtimeRetryAfter
        let values = [transportValue, errorValue]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 >= 0 }
        guard let availableValue = values.max() else { return nil }
        return min(availableValue, 300)
    }

    private func reconnectDelayNanoseconds(seconds: TimeInterval) -> UInt64 {
        let scaledSeconds = max(0, seconds * reconnectDelayScale)
        guard scaledSeconds > 0 else { return 0 }
        return UInt64((scaledSeconds * 1_000_000_000).rounded())
    }

    private static func redactedEndpointSummary(_ url: URL) -> String {
        let sanitizedURL = RealtimeEndpointURLSanitizer.removingCredentials(from: url)
        guard var components = URLComponents(url: sanitizedURL, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid-url>"
    }

    private static func transportName(_ kind: RealtimeActiveTransportKind?) -> String {
        switch kind {
        case .webSocket:
            return "websocket"
        case .quic:
            return "quic"
        case nil:
            return "none"
        }
    }

    private static func redactedErrorSummary(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        return String(reflecting: type(of: error))
    }

    private func handleNetworkPathStatus(_ status: RealtimeNetworkPathStatus) {
        let previousStatus = lastNetworkPathStatus
        lastNetworkPathStatus = status
        guard previousStatus == .unsatisfied, status == .satisfied else { return }
        reconnectImmediatelyAfterNetworkChange()
    }

    private func reconnectImmediatelyAfterNetworkChange() {
        guard canReconnect?() == true else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        let hadActiveLeg = socket != nil || quicConnection != nil || quicConnectTask != nil
        if hadActiveLeg {
            connectionGeneration &+= 1
            stopActiveLeg()
            onDisconnected?()
        } else {
            transition(to: .idle)
        }
        startFromProvider()
    }
}

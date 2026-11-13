import CryptoKit // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_BEGIN
import Foundation
import Network

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
        // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023
        case operationRejected = "OPERATION_REJECTED_CONNECTION_KEPT"
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
        // WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023
        if handling == .operationRejected { return false }
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
    var messageFlow: RealtimeMessageFlowSignpost? // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110
    // WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_BEGIN
    /// The native delivery may hand its flow to the App ingress only once.
    func takeMessageFlow() -> RealtimeMessageFlowSignpost? {
        defer { messageFlow = nil }
        return messageFlow
    }
    // WDT_IOS1_SIGNPOST_SP1_OWNERSHIP_20261110_END
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
} // WDT_IOS1_REALTIME_COMMIT_CONSUMPTION_SIGNPOSTS_20261110_END

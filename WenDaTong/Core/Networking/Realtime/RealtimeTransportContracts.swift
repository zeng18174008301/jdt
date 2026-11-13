import CryptoKit
import Foundation
import IM4Data
import Network

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
    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String, priority: Bool)
}

extension RealtimeTransporting {
    func subscribe(channelID: String, channelType: String, tenantID: String, imUID: String, deviceID: String, priority: Bool) {
        subscribe(channelID: channelID, channelType: channelType, tenantID: tenantID, imUID: imUID, deviceID: deviceID)
    }

    func start(request: RealtimeConnectionRequest) {
        start(url: request.url, token: request.token)
    }
}

enum RealtimeConnectionState: String, Equatable, Sendable {
    case idle
    case dialing
    case awaitingAck = "awaiting_ack"
    case connected
    case backoff
}

/// Diagnostic values are closed labels only; never retain a request or raw error.
// WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023_BEGIN
enum RealtimeErrorScopePolicy {
    static func isConnectionFailure(code: String, envelope: RealtimeEnvelope, matchesConnectRequest: Bool) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["connect_failed", "unauthorized", "connect_required"].contains(normalized) { return true }
        guard normalized == "forbidden" else { return false }
        if matchesConnectRequest { return true }
        var payload = envelope.payload
        for container in ["error", "data", "payload"] {
            for (key, value) in envelope.payload[container]?.objectValue ?? [:] where payload[key] == nil {
                payload[key] = value
            }
        }
        let scope = payload["scope"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // A bare operation denial is not evidence that the authenticated connection failed.
        return ["connection", "session", "global", "account", "tenant", "workspace"].contains(scope)
    }
}
// WDT_CHAT_FIX6_REALTIME_ERROR_SCOPE_20261023_END

// WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_BEGIN
typealias RealtimeBatchExpansionResult = IM4Data.RealtimeBatchExpansionResult<RealtimeEnvelope> // WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111
// WDT_IOS1_REALTIME_BACKGROUND_DECODE_20261110_END

typealias RealtimeBatchExpander = IM4Data.RealtimeBatchExpander // WDT_IOS1_DATA17_RAW_REALTIME_FRAME_20261111

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

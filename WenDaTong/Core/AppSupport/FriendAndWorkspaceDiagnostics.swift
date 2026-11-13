import Combine // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_BEGIN
import Foundation
import Darwin
import AudioToolbox
import AVFoundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import os
import CryptoKit

/// The accept request has one local attempt identity across routing, transport
/// and error normalization. Only hashes and closed protocol labels are logged.
struct FriendAcceptanceDiagnostic: Sendable {
    enum Stage: String { case apiEntered, routing, preparing, transportStarted, response, apiSucceeded, apiFailed }
    private struct ResponseMetadata: Decodable {
        struct ErrorCode: Decodable { let code: String? }
        let ok: Bool?
        let error: ErrorCode?
        let code: String?
        let trace_id: String?
    }
    let path: String
    private let identity: String

    init(context: IMAPIContext, applicationID: String, attemptID: String = UUID().uuidString) {
        path = "/api/tenant/friends/applications/\(applicationID.urlPathEncoded)/accept"
        identity = "attempt_sha12=\(Self.fingerprint(attemptID)) app_sha12=\(Self.fingerprint(context.appID)) account_sha12=\(Self.fingerprint(context.accountID)) uid_sha12=\(Self.fingerprint(context.imUID)) tenant_sha12=\(Self.fingerprint(context.tenantID)) application_sha12=\(Self.fingerprint(applicationID))"
    }

    func matches(method: String, path: String) -> Bool {
        method.uppercased() == "POST" && path == self.path
    }

    static func fingerprint(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "NONE" }
        return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func summary(_ stage: Stage, endpoint: URL? = nil, status: Int? = nil,
                 responseData: Data? = nil, requestID: String? = nil, error: Error? = nil) -> String {
        let metadata = responseData.flatMap { try? JSONDecoder().decode(ResponseMetadata.self, from: $0) }
        let rawCode = metadata?.error?.code ?? metadata?.code ?? Self.clientErrorCode(error)
        let allowedCodes: Set<String> = [
            "unauthorized", "forbidden", "missing_token", "invalid_token", "expired_token", "stale_access_token",
            "session_expired", "session_revoked", "device_revoked", "account_locked", "account_disabled",
            "tenant_member_disabled", "tenant_member_not_found", "tenant_service_stopped", "security_blocked",
            "rate_limited", "tenant_review_pending", "not_found", "conflict", "bad_request", "not_friends",
            "service_unavailable", "internal_database_error", "policy_storage_unavailable",
            "workspace_identity_unlinked", "workspace_directory_unavailable",
            "client_cancelled", "client_transport", "client_decode", "client_server", "client_empty_response",
            "client_missing_context", "client_bad_url", "client_forced_auth", "client_http_status", "client_other"
        ]
        let code = rawCode.isEmpty ? "NONE" : (allowedCodes.contains(rawCode) ? rawCode : "OTHER")
        let safeStatus = status.flatMap { (100...599).contains($0) ? String($0) : nil } ?? "NONE"
        let origin = endpoint.map { "\($0.scheme ?? "")://\($0.host ?? ""):\($0.port ?? ($0.scheme == "https" ? 443 : 80))" }
        let ok = metadata?.ok.map { $0 ? "TRUE" : "FALSE" } ?? "UNKNOWN"
        return "friend_accept stage=\(stage.rawValue) \(identity) host_sha12=\(Self.fingerprint(origin)) status=\(safeStatus) envelope_ok=\(ok) code=\(code) code_sha12=\(Self.fingerprint(rawCode)) request_sha12=\(Self.fingerprint(requestID)) trace_sha12=\(Self.fingerprint(metadata?.trace_id))"
    }

    private static func clientErrorCode(_ error: Error?) -> String {
        guard let error else { return "" }
        if error is CancellationError { return "client_cancelled" }
        if error is URLError { return "client_transport" }
        if error is DecodingError { return "client_decode" }
        guard let error = error as? IMAPIError else { return "client_other" }
        switch error {
        case .businessForbidden(let code, _, _), .conflict(let code, _),
             .loginSecurity(let code, _, _), .rateLimited(let code, _, _, _): return code
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .securityBlocked: return "security_blocked"
        case .server: return "client_server"
        case .emptyResponse: return "client_empty_response"
        case .missingContext: return "client_missing_context"
        case .badURL: return "client_bad_url"
        case .forcedAuthRequired: return "client_forced_auth"
        case .httpStatus: return "client_http_status"
        }
    }

    func record(_ stage: Stage, endpoint: URL? = nil, status: Int? = nil,
                responseData: Data? = nil, requestID: String? = nil, error: Error? = nil) {
        let value = summary(stage, endpoint: endpoint, status: status, responseData: responseData, requestID: requestID, error: error)
        Self.logger.notice("\(value, privacy: .public)")
    }
    private static let logger = Logger(subsystem: "com.jianhuitongqiyetest.app", category: "friend-accept")
}

/// Only closed labels can reach the persistent sync log. Never interpolate an
/// error, request, context, URL or server-supplied value into this channel.
struct SyncFailureDiagnostic: Hashable, Sendable {
    // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：真机性能分析期间节流重复诊断日志，避免日志系统放大卡顿
    private static let logThrottle = SyncFailureDiagnosticLogThrottle()

    private static func persistNotice(
        _ summary: String,
        throttleKey: String,
        force: Bool = false
    ) {
        let decision = logThrottle.decision(for: throttleKey, force: force)
        guard decision.shouldLog else { return }
        let line = decision.suppressedCount > 0
            ? "\(summary) suppressed=\(decision.suppressedCount)"
            : summary
        logger.notice("\(line, privacy: .public)")
    }
    // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束

    // Preserve the server's rejection class before the existing user-facing
    // error conversion discards it. Only fixed session/sync paths and codes
    // enter unified logging; no URL query, body, credential or error text does.
    struct SessionRequestFailure {
        let summary: String

        init?(method: String, path: String, status: Int?, code: String, requestSummary: String?) {
            let method = method.uppercased()
            let fixedPath: String
            switch (method, path) {
            case ("GET", "/api/rtc/calls"), ("GET", "/api/rtc/calls/events"),
                 ("POST", "/api/im/conversations/sync"), ("POST", "/api/im/sync"),
                 ("POST", "/api/platform/auth/register"), ("GET", "/api/platform/auth/register/status"),
                 ("POST", "/api/platform/auth/register/session"), ("POST", "/api/tenant/auth/platform-entry"),
                 ("POST", "/api/platform/auth/session/refresh"), ("POST", "/api/tenant/auth/session/refresh"),
                 ("POST", "/api/tenant/auth/refresh"),
                 ("POST", "/api/tenant/users/profiles"):
                fixedPath = path
            default:
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard method == "POST", parts.count == 7, parts[0].isEmpty,
                      parts[1] == "api", parts[2] == "platform" else { return nil }
                if parts[3] == "tenants", UUID(uuidString: String(parts[4])) != nil,
                   parts[5] == "session", parts[6] == "refresh" {
                    fixedPath = "/api/platform/tenants/{tenant}/session/refresh"
                } else if parts[3] == "me", parts[4] == "tenants",
                          UUID(uuidString: String(parts[5])) != nil, parts[6] == "enter" {
                    fixedPath = "/api/platform/me/tenants/{tenant}/enter"
                } else { return nil }
            }
            let allowedCodes: Set<String> = [
                "missing_token", "invalid_token", "expired_token", "stale_access_token",
                "unauthorized", "forbidden", "session_expired", "refresh_token_expired",
                "session_revoked", "refresh_token_reused", "reauth_required",
                "device_not_found", "device_disabled", "device_app_mismatch", "device_revoked",
                "account_locked", "account_disabled", "tenant_member_disabled", "tenant_member_not_found",
                "tenant_service_stopped", "security_blocked", "rate_limited",
                "audit_write_failed", "token_sign_failed", "registration_session_unauthorized",
                "transport", "invalid_response", "decode_envelope_failed", "json_decode_failed", "empty_data"
            ]
            let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let safeCode = allowedCodes.contains(normalizedCode) ? normalizedCode : "OTHER"
            let safeStatus = status.flatMap { (100...599).contains($0) ? String($0) : nil } ?? "NONE"
            let fingerprint = requestSummary ?? ""
            let hash = fingerprint.hasPrefix("hash:") ? String(fingerprint.dropFirst(5)) : ""
            let safeRequest = !hash.isEmpty && hash.count <= 8
                && hash.allSatisfy { "0123456789abcdef".contains($0) } ? fingerprint : "NONE"
            summary = "session_http_failure method=\(method) path=\(fixedPath) status=\(safeStatus) code=\(safeCode) request=\(safeRequest)"
        }
    }

    static func persistSessionRequestFailure(_ event: SessionRequestFailure) {
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：会话请求失败日志保持即时输出
        persistNotice(event.summary, throttleKey: event.summary, force: true)
        // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
    }

    enum Endpoint: String, Sendable { case history = "IM_HISTORY", tenantContext = "TENANT_CONTEXT", workspaces = "WORKSPACES", tenantProfile = "TENANT_PROFILE", meProfile = "ME_PROFILE", attachmentUpload = "ATTACHMENT_UPLOAD", conversationPage = "CONVERSATION_PAGE", conversationSync = "CONVERSATION_SYNC" }
    enum PrimaryOutcome: String, Sendable {
        case missingSession = "MISSING_SESSION", skipped = "SKIPPED", alreadyRunning = "ALREADY_RUNNING"
        case obsolete = "OBSOLETE_REFRESH", complete = "COMPLETE", incomplete = "INCOMPLETE"
        case authorityChanged = "AUTHORITY_CHANGED", cancelled = "CANCELLED"
        case credentialsAdvanced = "CREDENTIALS_ADVANCED"
    }
    static func persistPrimaryOutcome(_ outcome: PrimaryOutcome) {
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：重复快照状态节流，异常状态即时输出
        let summary = "primary_snapshot_result=\(outcome.rawValue)"
        let force: Bool
        switch outcome {
        case .skipped, .alreadyRunning, .complete:
            force = false
        case .missingSession, .obsolete, .incomplete, .authorityChanged, .cancelled, .credentialsAdvanced:
            force = true
        }
        persistNotice(summary, throttleKey: "primary_snapshot_result|\(outcome.rawValue)", force: force)
        // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
    }
    // Existing networking intentionally maps several HTTP/decode failures to
    // .server(String). Keep that error contract unchanged; a task-local, typed
    // observation carries only the lost classification back to the existing catch.
    final class HTTPObservation: @unchecked Sendable {
        let endpoint: Endpoint
        private let lock = NSLock()
        private var storedFailure: Failure?
        private var responseStatus: Int?
        private var requestFingerprint: String?
        private var primaryFailurePath: String?
        private var storedUploadFailure: AttachmentUploadFailure?
        private var finished = false
        private let startedAt = DispatchTime.now().uptimeNanoseconds
        init(_ endpoint: Endpoint) { self.endpoint = endpoint }
        var failure: Failure? { lock.withLock { storedFailure } }
        var uploadFailure: AttachmentUploadFailure? { lock.withLock { storedUploadFailure } }
        func recordPrimaryResponse(path: String, status: Int, fingerprint: String?, resolvedPath: String? = nil) {
            guard (endpoint == .conversationPage && path == "/api/im/conversations/page")
                || (endpoint == .conversationSync && path == "/api/im/conversations/sync") else { return }
            let hash = fingerprint?.hasPrefix("hash:") == true ? String(fingerprint!.dropFirst(5)) : ""
            let safeFingerprint = hash.count == 8 && hash.allSatisfy { "0123456789abcdef".contains($0) }
                ? "hash:\(hash)" : nil
            lock.withLock {
                guard !finished else { return }
                responseStatus = (100...599).contains(status) ? status : nil
                requestFingerprint = safeFingerprint
                // Compare failures with this request's exact constructed URL path,
                // including supported base prefixes. Never accept arbitrary suffixes.
                primaryFailurePath = resolvedPath ?? path
            }
        }
        func beginUploadStep() {
            guard endpoint == .attachmentUpload else { return }
            lock.withLock { if !finished { storedUploadFailure = nil } }
        }
        func recordUploadFailure(_ value: AttachmentUploadFailure) {
            guard endpoint == .attachmentUpload else { return }
            lock.withLock { if !finished { storedUploadFailure = value } }
        }
        func resolvedUploadFailure(error: Error) -> AttachmentUploadFailure {
            let fallback = AttachmentUploadFailure(error: error)
            guard let observed = uploadFailure else { return fallback }
            // Preserve a typed transport distinction that the generic HTTP log lacks.
            if observed.code == .transport, fallback.code != .unknown { return fallback }
            return observed
        }
        @MainActor
        func captureUploadStep<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
            beginUploadStep()
            let step = HTTPObservation(.attachmentUpload)
            defer { step.finish() }
            return try await SyncFailureDiagnostic.$httpObservation.withValue(step) {
                do {
                    return try await operation()
                } catch {
                    recordUploadFailure(step.resolvedUploadFailure(error: error))
                    throw error
                }
            }
        }
        func finish() { lock.withLock { finished = true } }
        /// Reports the decoded request outcome, not whether AppState accepted its generation.
        @MainActor
        func perform<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
            do {
                let value = try await operation()
                persistResult(error: nil)
                return value
            } catch {
                persistResult(error: error)
                throw error
            }
        }
        func result(error: Error?, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Result {
            let classified = error.map { Failure(error: $0) }
            let metadata = lock.withLock { (responseStatus, requestFingerprint) }
            return Result(endpoint: endpoint,
                          failure: classified == .other ? (failure ?? classified) : classified,
                          elapsedMS: now >= startedAt ? (now - startedAt) / 1_000_000 : 0,
                          responseStatus: metadata.0, requestFingerprint: metadata.1)
        }
        private func persistResult(error: Error?) {
            let event = result(error: error)
            // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：成功请求结果按端点节流，失败结果即时输出
            let resultLabel = event.failure?.rawValue ?? "SUCCESS"
            let statusLabel = event.responseStatus.map(String.init) ?? "NONE"
            SyncFailureDiagnostic.persistNotice(
                event.summary,
                throttleKey: "sync_request_result|\(event.endpoint.rawValue)|\(resultLabel)|\(statusLabel)",
                force: event.failure != nil
            )
            // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
        }
        func record(path: String, status: Int?, code: String) {
            if endpoint == .attachmentUpload {
                // This instance is bound only to one upload attempt. No path, request
                // ID or raw error text is retained; safe fields survive lossy throws.
                let kind: AttachmentUploadFailure.Code
                switch code {
                case "transport": kind = .transport
                case "invalid_response": kind = .invalidResponse
                case "decode_envelope_failed", "json_decode_failed": kind = .decode
                case "empty_data": kind = .emptyData
                default: kind = status.map { (200..<300).contains($0) ? .envelope : .http } ?? .unknown
                }
                let internalCodes = ["transport", "invalid_response", "decode_envelope_failed", "json_decode_failed", "empty_data", "api_error", "http_status"]
                recordUploadFailure(AttachmentUploadFailure(
                    code: kind, httpStatus: status,
                    serverCode: internalCodes.contains(code) || code.hasPrefix("http_") ? nil : code
                ))
                return
            }
            let expected: String
            switch endpoint {
            case .history: expected = "/api/im/sync"
            case .conversationPage: expected = "/api/im/conversations/page"
            case .conversationSync: expected = "/api/im/conversations/sync"
            case .tenantContext: expected = "/api/tenant/context"
            case .workspaces: expected = "/api/tenant/workspaces"
            case .tenantProfile: expected = "/api/tenant/profile"
            case .meProfile: expected = "/api/tenant/me/profile"
            case .attachmentUpload: return
            }
            let failurePath = lock.withLock { primaryFailurePath } ?? expected
            guard path == failurePath else { return }
            let result: Failure?
            switch status ?? -1 {
            case 401: result = .unauthorized
            case 403: result = .forbidden
            case 500...599: result = .server
            case 200...299 where code == "json_decode_failed" || code == "decode_envelope_failed" || code == "empty_data": result = .decode
            default: result = nil
            }
            lock.withLock {
                guard !finished else { return }
                storedFailure = result
            }
        }
    }
    @TaskLocal static var httpObservation: HTTPObservation?
    @TaskLocal static var friendAcceptance: FriendAcceptanceDiagnostic?
    enum Failure: String, Sendable {
        case unauthorized = "HTTP_401", forbidden = "HTTP_403", server = "HTTP_5XX", httpOther = "HTTP_OTHER"
        case timeout = "TIMEOUT", dns = "DNS", connect = "CONNECT", tls = "TLS", offline = "OFFLINE"
        case cancelled = "CANCELLED", missingContext = "MISSING_CONTEXT", route = "ROUTE_CONTRACT", decode = "DECODE", other = "OTHER"
        case invalidSnapshot = "INVALID_SNAPSHOT", invalidCursor = "INVALID_CURSOR", cursorExpired = "CURSOR_EXPIRED"

        init(error: Error) {
            if error is CancellationError { self = .cancelled; return }
            if error is DecodingError { self = .decode; return }
            if let error = error as? ConversationPageFailure {
                switch error.code {
                case "invalid_snapshot": self = .invalidSnapshot
                case "invalid_cursor": self = .invalidCursor
                case "conversation_page_cursor_expired": self = .cursorExpired
                default: self = (500...599).contains(error.statusCode) ? .server : .httpOther
                }
                return
            }
            if let error = error as? URLError {
                switch error.code {
                case .cancelled: self = .cancelled
                case .timedOut: self = .timeout
                case .cannotFindHost, .dnsLookupFailed: self = .dns
                case .cannotConnectToHost, .networkConnectionLost: self = .connect
                case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: self = .offline
                case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                     .clientCertificateRequired: self = .tls
                default: self = .other
                }
                return
            }
            if let error = error as? IMAPIError {
                switch error {
                case .unauthorized: self = .unauthorized
                case .forbidden: self = .forbidden
                case .httpStatus(let status, _):
                    switch status {
                    case 401: self = .unauthorized
                    case 403: self = .forbidden
                    case 500...599: self = .server
                    default: self = .httpOther
                    }
                case .missingContext: self = .missingContext
                case .badURL: self = .route
                case .businessForbidden(let code, _, _):
                    switch code {
                    case "app_context_mismatch", "app_domain_app_mismatch", "tenant_context_mismatch",
                         "route_tenant_mismatch", "bootstrap_host_mismatch", "route_host_mismatch",
                         "route_hash_mismatch", "config_hash_mismatch", "route_revision_rejected",
                         "route_revision_conflict", "route_revision_rollback", "route_contract_mismatch",
                         "route_contract_required": self = .route
                    default: self = .other
                    }
                default: self = .other
                }
                return
            }
            self = .other
        }
    }
    enum Recovery: String, Sendable { case notApplicable = "NOT_APPLICABLE", notAllowed = "RECOVERY_NOT_ALLOWED", noRefreshAuthority = "NO_REFRESH_AUTHORITY", attempted = "RECOVERY_SCHEDULED", deviceRevoked = "DEVICE_REVOKED" }
    let endpoint: Endpoint
    let failure: Failure
    let recovery: Recovery
    var summary: String { "sync_failure endpoint=\(endpoint.rawValue) error=\(failure.rawValue) recovery=\(recovery.rawValue)" }
    struct Result: Equatable, Sendable {
        let endpoint: Endpoint
        let failure: Failure?
        let elapsedMS: UInt64
        var responseStatus: Int? = nil
        var requestFingerprint: String? = nil
        var summary: String {
            let base = "sync_request_result endpoint=\(endpoint.rawValue) result=\(failure?.rawValue ?? "SUCCESS") elapsed_ms=\(elapsedMS)"
            guard endpoint == .conversationPage || endpoint == .conversationSync else { return base }
            return "\(base) status=\(responseStatus.map(String.init) ?? "NONE") request=\(requestFingerprint ?? "NONE")"
        }
    }
    static func persistConnection(_ event: RealtimeConnectionDiagnostic) {
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：Realtime 重复成功状态节流，失败状态即时输出
        let stateAfter = event.stateAfter?.rawValue ?? "UNPROVEN"
        let key = [
            "connection_result",
            event.stage.rawValue,
            event.result.label,
            event.transport.rawValue,
            event.serverCode.rawValue,
            event.handlingCode.rawValue,
            event.operation.rawValue,
            event.correlation.rawValue,
            event.scopeMatch.rawValue,
            event.handling.rawValue,
            event.currentAtReceipt ? "CURRENT" : "STALE",
            stateAfter,
            event.scopeAfter.rawValue
        ].joined(separator: "|")
        persistNotice(event.summary, throttleKey: key, force: event.isFailure)
        // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
    }
    private static let logger = Logger(subsystem: "com.jianhuitongqiyetest.app", category: "sync-failure")

    func persist() {
        // JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：同步失败摘要保持即时输出
        Self.persistNotice(summary, throttleKey: summary, force: true)
        // JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束
    }
}

// JHT_MOD_BEGIN TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改开始：诊断日志节流器，可整体撤回
private final class SyncFailureDiagnosticLogThrottle: @unchecked Sendable {
    struct Decision {
        let shouldLog: Bool
        let suppressedCount: Int
    }

    private let lock = NSLock()
    private let intervalNanoseconds: UInt64 = 1_500_000_000
    private var lastLoggedAtByKey: [String: UInt64] = [:]
    private var suppressedCountByKey: [String: Int] = [:]

    func decision(
        for key: String,
        force: Bool,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Decision {
        lock.lock()
        defer { lock.unlock() }

        if force {
            let suppressedCount = suppressedCountByKey.removeValue(forKey: key) ?? 0
            lastLoggedAtByKey[key] = now
            return Decision(shouldLog: true, suppressedCount: suppressedCount)
        }

        if let lastLoggedAt = lastLoggedAtByKey[key],
           now >= lastLoggedAt,
           now - lastLoggedAt < intervalNanoseconds {
            suppressedCountByKey[key, default: 0] += 1
            return Decision(shouldLog: false, suppressedCount: 0)
        }

        let suppressedCount = suppressedCountByKey.removeValue(forKey: key) ?? 0
        lastLoggedAtByKey[key] = now
        return Decision(shouldLog: true, suppressedCount: suppressedCount)
    }
}
// JHT_MOD_END TEMP_PERF_ANALYSIS_THROTTLE_DIAGNOSTIC_LOGS_20260912 - 修改结束

#if DEBUG
let registrationDiagnosticsLogger = Logger(subsystem: "com.jianhuitongqiyetest.app", category: "registration")
let workspaceEntryDiagnosticsLogger = Logger(subsystem: "com.jianhuitongqiyetest.app", category: "workspace-entry")

func recordRegistrationResolutionState(_ state: RegistrationResolutionState, elapsedSeconds: TimeInterval) {
    let elapsedMilliseconds = max(0, Int((elapsedSeconds * 1_000).rounded()))
    let message = "state=\(state.rawValue) elapsed_ms=\(elapsedMilliseconds)"
    UserDefaults.standard.set(
        message,
        forKey: "jianhuitong.debug.registration.lastSummary"
    )
    registrationDiagnosticsLogger.notice("\(message, privacy: .public)")
}

func recordRegistrationDiagnostic(_ state: RegistrationDiagnosticState, elapsedSeconds: TimeInterval) {
    let message = state.safeSummary(elapsedSeconds: elapsedSeconds)
    // Keep the existing business state/elapsed lastSummary contract unchanged.
    UserDefaults.standard.set(message, forKey: "jianhuitong.debug.registration.lastDiagnostic")
    registrationDiagnosticsLogger.notice("\(message, privacy: .public)")
}

func recordWorkspaceEntryDiagnosticSummary(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    UserDefaults.standard.set(
        "\(timestamp) \(message)",
        forKey: "jianhuitong.debug.workspaceEntry.lastSummary"
    )
    workspaceEntryDiagnosticsLogger.notice("\(message, privacy: .public)")
}
#endif

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
} // WDT_IOS1_SCOPED_MESSAGE_MEMORY_20261110_END

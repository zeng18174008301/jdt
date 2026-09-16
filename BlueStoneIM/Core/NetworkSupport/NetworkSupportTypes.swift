import Foundation

struct IMAPIRequestDescriptor: Sendable {
    let base: URL
    let path: String
    let method: String
    let hasBearerToken: Bool
}

enum IMAPIError: Error {
    case missingContext(String)
    case badURL(String)
    case unauthorized(String)
    case forbidden(String)
    case forcedAuthRequired(AppPolicyForcedAuthRequirement)
    case businessForbidden(code: String, message: String, error: APIEnvelopeError?)
    case conflict(code: String, message: String)
    case httpStatus(Int, message: String)
    case server(String)
    case securityBlocked(SecurityBlockedInfo)
    case loginSecurity(code: String, message: String, info: RemoteLoginSecurityInfo?)
    case rateLimited(code: String, message: String, retryAfterSeconds: Int?, lockedUntil: String?)
    case emptyResponse
}

enum BackendUserMessageSanitizer {
    static func sanitize(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lowered = trimmed.lowercased()
        if lowered == "no error" || lowered == "unknown error" || lowered == "<nil>" {
            return fallback
        }
        if containsSensitiveMarker(lowered) {
            return fallback
        }
        if lowered.contains("rate limit state is temporarily unavailable")
            || (lowered.contains("rate limit") && lowered.contains("temporarily unavailable")) {
            return "服务繁忙，请稍后重试"
        }
        if lowered.contains("rate limit") || lowered.contains("rate_limited") {
            return "操作过于频繁，请稍后再试"
        }
        return trimmed
    }

    static func sanitize(error: Error, fallback: String) -> String {
        let localized = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if let localized, !localized.isEmpty {
            raw = localized
        } else {
            raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitize(raw, fallback: fallback)
    }

    private static func containsSensitiveMarker(_ lowered: String) -> Bool {
        let markers = [
            "authorization",
            "bearer ",
            "token",
            "device_proof",
            "preauth_device",
            "preauth-device",
            "refresh_token",
            "entry_ticket",
            "im_token",
            "api_token",
            ".env",
            "env=",
            "dsn",
            "database",
            "sqlstate",
            "sql ",
            "pq:",
            "constraint",
            "duplicate key",
            "unique index",
            "platform_account_",
            "tenant_admin",
            "uq_",
            "_key",
            "private key",
            "private_key",
            "secret",
            "signature",
            "payload",
            "full json",
            "raw json",
            "header",
            "stack trace",
            "stacktrace",
            "traceback",
            "panic:",
            "goroutine ",
            "issuer-data",
            "issuer.env",
            ".pem",
            ".enckey",
            "private_seed",
            "access_key",
            "access key",
            "object key",
            "object_key",
            "secret_ref",
            "secret ref",
            "signer",
            "bucket",
            "ddl",
            "create index",
            "internal"
        ]
        return markers.contains { lowered.contains($0) }
            || lowered.range(of: #"\{[^\n]{0,400}[:\"][^\n]{0,400}\}"#, options: .regularExpression) != nil
            || lowered.range(of: #"(https?|wss?)://[^\s]+"#, options: .regularExpression) != nil
    }
}

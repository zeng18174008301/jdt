// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_BEGIN
import Foundation

public struct AttachmentUploadFailure: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Sendable {
        case localPersistence = "LOCAL_PERSISTENCE"
        case localFile = "LOCAL_FILE"
        case missingContext = "MISSING_CONTEXT"
        case route = "ROUTE"
        case requestEncoding = "REQUEST_ENCODING"
        case timeout = "NETWORK_TIMEOUT", dns = "NETWORK_DNS", tls = "NETWORK_TLS"
        case offline = "NETWORK_OFFLINE", transport = "NETWORK_TRANSPORT"
        case cancelled = "CANCELLED", invalidResponse = "INVALID_RESPONSE"
        case http = "HTTP", envelope = "ENVELOPE", decode = "DECODE_ENVELOPE"
        case emptyData = "EMPTY_DATA", policy = "POLICY", unknown = "UNKNOWN"
    }

    public let code: Code
    public let httpStatus: Int?
    public let serverCode: String?
    public let storageRequestID: String?

    public init(code: Code, httpStatus: Int? = nil, serverCode: String? = nil, storageRequestID: String? = nil) {
        self.code = code
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        // Syntax-only filtering is insufficient: a token can look like a code.
        // Unrecognized server codes are deliberately not copied into storage.
        let known: Set<String> = [
            "bad_request", "invalid_request", "invalid_payload", "invalid_argument",
            "unauthorized", "invalid_credentials", "forbidden", "not_friends",
            "conflict", "rate_limited", "security_blocked", "account_locked",
            "tenant_storage_not_configured", "tenant_storage_resource_unavailable",
            "tenant_storage_provider_unsupported", "tenant_storage_secret_unresolved",
            "tenant_storage_local_unavailable",
            "file_too_large", "unsupported_mime_type", "invalid_file_type",
            "file_not_found", "upload_not_found", "upload_not_completed",
            "checksum_mismatch", "size_mismatch", "internal_error",
            "service_unavailable", "unrecognized_server_code",
            "signaturedoesnotmatch", "accessdenied", "requesttimetooskewed",
            "invalidaccesskeyid", "securitytokenexpired", "invalidsecuritytoken",
            "requestexpired", "invaliddigest", "baddigest", "invalidargument", "filealreadyexists", "object_not_found"
        ]
        if let serverCode, !serverCode.isEmpty {
            let normalized = serverCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.serverCode = known.contains(normalized) ? normalized : "unrecognized_server_code"
        } else {
            self.serverCode = nil
        }
        // Keep only the standard 24-hex OSS request ID; omit other header text.
        if let storageRequestID,
           storageRequestID.utf8.count == 24,
           storageRequestID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            self.storageRequestID = storageRequestID
        } else {
            self.storageRequestID = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case code, httpStatus, serverCode, storageRequestID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode = try? values.decode(String.self, forKey: .code)
        self.init(
            code: rawCode.flatMap(Code.init(rawValue:)) ?? .unknown,
            httpStatus: try? values.decode(Int.self, forKey: .httpStatus),
            serverCode: try? values.decode(String.self, forKey: .serverCode),
            storageRequestID: try? values.decode(String.self, forKey: .storageRequestID)
        )
    }

    public var detail: String {
        var parts = [code.rawValue]
        if let httpStatus { parts.append("HTTP \(httpStatus)") }
        if let serverCode { parts.append(serverCode) }
        if let storageRequestID { parts.append("request_id=\(storageRequestID)") }
        return parts.joined(separator: " · ")
    }
}
// WDT_IOS1_DOMAIN_MODULE_PROTOTYPE_20261110_END

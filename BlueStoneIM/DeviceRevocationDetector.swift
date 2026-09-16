import Foundation

extension Notification.Name {
    static let imCurrentDeviceRevoked = Notification.Name("BlueStoneIM.currentDeviceRevoked")
}

enum DeviceRevocationDetector {
    static let logoutMessage = "当前设备已被管理员踢下线，请重新登录"

    static func matches(error: APIEnvelopeError?) -> Bool {
        guard let error else { return false }
        return matches(
            code: error.code,
            reasonCode: error.reasonCode,
            message: error.message,
            reason: error.reason
        )
    }

    static func matches(error: Error) -> Bool {
        guard let apiError = error as? IMAPIError else {
            return matches(text: String(describing: error))
        }
        switch apiError {
        case .unauthorized(let message), .forbidden(let message), .httpStatus(_, let message), .server(let message):
            return matches(text: message)
        case .businessForbidden(let code, let message, let error):
            return matches(code: code, reasonCode: error?.reasonCode, message: message, reason: error?.reason)
                || matches(error: error)
        case .conflict(let code, let message),
             .loginSecurity(let code, let message, _),
             .rateLimited(let code, let message, _, _):
            return matches(code: code, message: message)
        case .securityBlocked(_), .forcedAuthRequired(_), .missingContext(_), .badURL(_), .emptyResponse:
            return false
        }
    }

    static func matches(envelope: RealtimeEnvelope) -> Bool {
        guard envelope.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "error" else {
            return false
        }
        let payload = envelope.payload
        let nestedError = payload["error"]?.objectValue ?? [:]
        return matches(payload: payload) || matches(payload: nestedError)
    }

    static func matches(code: String?, reasonCode: String? = nil, message: String?, reason: String? = nil) -> Bool {
        matches(texts: [code, reasonCode, message, reason])
    }

    private static func matches(payload: [String: JSONValue]) -> Bool {
        matches(
            code: string(payload, keys: ["code"]),
            reasonCode: string(payload, keys: ["reason_code", "reasonCode"]),
            message: string(payload, keys: ["message"]),
            reason: string(payload, keys: ["reason", "reason_text", "reasonText"])
        )
    }

    private static func string(_ payload: [String: JSONValue], keys: [String]) -> String? {
        keys.compactMap { key in
            payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first { !$0.isEmpty }
    }

    private static func matches(texts: [String?]) -> Bool {
        let joined = texts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return matches(text: joined)
    }

    private static func matches(text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let compact = lowered
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return compact.contains("devicekicked")
            || compact.contains("devicerevoked")
            || compact.contains("devicedisabled")
            || compact.contains("devicebanned")
            || compact.contains("devicebindingviolation")
    }
}

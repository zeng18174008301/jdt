import Foundation

struct IMSessionRefreshRejectionError: LocalizedError {
    let statusCode: Int
    let code: String
    let userMessage: String

    var errorDescription: String? { userMessage }
}

enum RTCCredentialError: LocalizedError, Equatable {
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "RTC 凭证已失效" : normalized
        }
    }
}


enum IMRuntimeBuildPolicy {
    static let formalBuildInfoKey = "WXTFormalBuild"

    static func allowsRuntimeAPIBaseOverride(
        debugBuild: Bool,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Bool {
        debugBuild && !isFormalBuild(info: info)
    }

    static func isFormalBuild(info: [String: Any]) -> Bool {
        parseBoolean(info[formalBuildInfoKey]) == true
    }

    private static func parseBoolean(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber {
            if number == 0 { return false }
            if number == 1 { return true }
            return nil
        }
        guard let value = raw as? String else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}

struct SecurityBlockedInfo: Error, Equatable {
    let scope: String
    let tenantID: String
    let subjectType: String
    let reasonCode: String
    let blockType: String
    let status: String
    let expiresAt: String
    let remainingSeconds: Int?

    init(
        scope: String = "",
        tenantID: String = "",
        subjectType: String = "",
        reasonCode: String = "",
        blockType: String = "",
        status: String = "",
        expiresAt: String = "",
        remainingSeconds: Int? = nil
    ) {
        self.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectType = subjectType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.reasonCode = reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.blockType = blockType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.status = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.expiresAt = expiresAt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remainingSeconds = remainingSeconds
    }

    init(error: APIEnvelopeError?) {
        self.init(
            scope: error?.scope ?? "",
            tenantID: error?.tenantID ?? "",
            subjectType: error?.subjectType ?? "",
            reasonCode: error?.reasonCode ?? "",
            blockType: error?.blockType ?? "",
            status: error?.status ?? "",
            expiresAt: error?.expiresAt ?? error?.lockedUntil ?? "",
            remainingSeconds: error?.remainingSeconds ?? error?.retryAfterSeconds
        )
    }

    var isTenantScoped: Bool {
        if ["tenant", "workspace", "enterprise"].contains(scope) { return true }
        if ["tenant", "workspace", "tenant_member", "member"].contains(subjectType) { return true }
        return !tenantID.isEmpty && !isGlobalScoped
    }

    var isGlobalScoped: Bool {
        if ["global", "platform", "account", "device", "ip", "phone", "admin", "admin_account"].contains(scope) {
            return true
        }
        if ["account", "device", "ip", "global", "admin_account", "phone"].contains(subjectType) {
            return true
        }
        return false
    }

    var userMessage: String {
        let base = "访问已被安全策略限制"
        if blockType == "permanent" || status == "permanent" {
            return "\(base)，请联系管理员"
        }
        if let seconds = remainingSeconds, seconds > 0 {
            return "\(base)，约 \(Self.durationText(seconds: seconds)) 后可再试"
        }
        if let expiresText = Self.expiresText(expiresAt) {
            return "\(base)，\(expiresText) 后可再试"
        }
        return base
    }

    private static func durationText(seconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(seconds) / 60.0)))
        if minutes < 60 {
            return "\(minutes) 分钟"
        }
        let hours = max(1, Int(ceil(Double(minutes) / 60.0)))
        if hours < 24 {
            return "\(hours) 小时"
        }
        let days = max(1, Int(ceil(Double(hours) / 24.0)))
        return "\(days) 天"
    }

    private static func expiresText(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let date = parseDate(value) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return out.string(from: date)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_BEGIN
import Foundation

public enum IMSessionLifetimeMode: String, Codable, Equatable, Sendable {
    case absolute
    case untilRevoked = "until_revoked"

    public static func authoritativeValue(_ raw: String?) -> IMSessionLifetimeMode {
        guard let raw else { return .absolute }
        return IMSessionLifetimeMode(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .absolute
    }
}
// WDT_IOS1_DATA_SESSION_LOGIN_WORKSPACE_VALUES_20261110_END

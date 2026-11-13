// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_BEGIN
import Foundation

/// The existing App bootstrap codec remains responsible for wire normalization.
/// Data needs only the raw host fallback used by legacy persisted entries.
public protocol IMAppBootstrapLastGoodValue: Codable, Equatable {
    var bootstrapHost: String { get }
}

public struct IMAppBootstrapLastGoodEntry<Bootstrap: IMAppBootstrapLastGoodValue>: Codable {
    public let bootstrap: Bootstrap
    public let servingHost: String
    public let savedAt: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case bootstrap
        case servingHost
        case savedAt
    }

    public init(bootstrap: Bootstrap, servingHost: String, savedAt: TimeInterval) {
        self.bootstrap = bootstrap
        self.servingHost = servingHost
        self.savedAt = savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bootstrap = try container.decode(Bootstrap.self, forKey: .bootstrap)
        servingHost = try container.decodeIfPresent(String.self, forKey: .servingHost)
            ?? bootstrap.bootstrapHost
        savedAt = try container.decode(TimeInterval.self, forKey: .savedAt)
    }
}

public struct IMAppBootstrapLastGoodSnapshot<Bootstrap: IMAppBootstrapLastGoodValue>: Equatable {
    public let bootstrap: Bootstrap
    public let servingHost: String
    public let savedAt: TimeInterval

    public init(bootstrap: Bootstrap, servingHost: String, savedAt: TimeInterval) {
        self.bootstrap = bootstrap
        self.servingHost = servingHost
        self.savedAt = savedAt
    }
}

public enum IMAppBootstrapLastGoodRecordStore {
    public static let storageKey = "im2.appBootstrap.lastGood.v3"
    public static let previousStorageKey = "im2.appBootstrap.lastGood.v2"
    public static let legacyStorageKey = "im2.appBootstrap.lastGood.v1"

    public static func storedEntries<Bootstrap: IMAppBootstrapLastGoodValue>(
        defaults: UserDefaults,
        key: String = storageKey
    ) -> [String: IMAppBootstrapLastGoodEntry<Bootstrap>] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: IMAppBootstrapLastGoodEntry<Bootstrap>].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public static func persist<Bootstrap: IMAppBootstrapLastGoodValue>(
        _ entries: [String: IMAppBootstrapLastGoodEntry<Bootstrap>],
        defaults: UserDefaults,
        key: String = storageKey
    ) {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    public static func removeEntries(defaults: UserDefaults, key: String) {
        defaults.removeObject(forKey: key)
    }
}
// WDT_IOS1_BOOTSTRAP_DATA15_16_20261111_END

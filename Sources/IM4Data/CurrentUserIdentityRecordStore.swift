// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_BEGIN
import Foundation

public enum CurrentUserIdentityRecordStore {
    private static let storageKey = "im2.ios.currentUserIdentities"

    public static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    public static func loadAll(defaults: UserDefaults) -> [String: IMStoredCurrentUserIdentity] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: IMStoredCurrentUserIdentity].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public static func persist(_ identities: [String: IMStoredCurrentUserIdentity], defaults: UserDefaults) {
        if identities.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(identities) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
// WDT_IOS1_DATA_CURRENT_USER_IDENTITY_CACHE_20261111_END

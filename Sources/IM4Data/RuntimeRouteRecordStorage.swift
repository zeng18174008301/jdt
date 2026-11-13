// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_BEGIN
import Foundation
import CryptoKit

/// Concrete atomic-record IO. The existing App process lock serializes every access and its surrounding authority decisions.
public final class RuntimeRouteRecordStorage {
    private let defaults: UserDefaults
    private let prefix = "wxt.runtime.routes.v2."
    // Still read persisted bytes before using this per-instance decoded cache.
    private var lastDecodedRecord: (key: String, data: Data, value: IMRuntimeRouteAtomicRecord)?
    private var lastStorageKey: (appID: String, tenantID: String, key: String)?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func record(appID: String, tenantID: String?) -> IMRuntimeRouteAtomicRecord {
        let storageKey = key(appID: appID, tenantID: tenantID)
        guard let data = defaults.data(forKey: storageKey) else {
            return .init(storedCurrent: nil, previous: nil, recoveryByService: [:])
        }
        if let cached = lastDecodedRecord, cached.key == storageKey, cached.data == data {
            return cached.value
        }
        guard let value = try? JSONDecoder().decode(IMRuntimeRouteAtomicRecord.self, from: data) else {
            return .init(storedCurrent: nil, previous: nil, recoveryByService: [:])
        }
        lastDecodedRecord = (storageKey, data, value)
        return value
    }

    public func originalBytes(appID: String, tenantID: String?) -> Data? {
        defaults.data(forKey: key(appID: appID, tenantID: tenantID))
    }

    public func restoreBytes(_ originalBytes: Data?, appID: String, tenantID: String?) {
        let storageKey = key(appID: appID, tenantID: tenantID)
        if let originalBytes { defaults.set(originalBytes, forKey: storageKey) }
        else { defaults.removeObject(forKey: storageKey) }
        _ = defaults.synchronize()
    }

    public func persist(_ value: IMRuntimeRouteAtomicRecord, appID: String, tenantID: String?) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: key(appID: appID, tenantID: tenantID)); return defaults.synchronize()
    }
    private func key(appID: String, tenantID: String?) -> String {
        let tenantID = tenantID ?? ""
        // The key hashes UTF-8 bytes, so compare the bytes rather than using
        // String's canonical-equivalence comparison.
        if let cached = lastStorageKey,
           cached.appID.utf8.elementsEqual(appID.utf8),
           cached.tenantID.utf8.elementsEqual(tenantID.utf8) {
            return cached.key
        }
        let digest = SHA256.hash(data: Data("\(appID)\u{0}\(tenantID)".utf8))
        let key = prefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        lastStorageKey = (appID, tenantID, key)
        return key
    }
}
// WDT_IOS1_DATA_RUNTIME_ROUTE_RECORDS_20261111_END

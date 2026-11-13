// WDT_IOS1_STICKER_MANIFEST_DATA_20261111_BEGIN
import Foundation
import IM4Domain

public final class StickerManifestRecordStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load(scope: String) -> CachedStickerManifest? {
        let key = cacheStorageKey(scope: scope)
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let cached = try? decoder.decode(CachedStickerManifest.self, from: data),
              cached.schemaVersion == 1,
              cached.scope == scope else {
            return nil
        }
        return cached
    }

    public func persist(_ items: [StickerLibraryItem], scope: String) {
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { return }
        let manifest = CachedStickerManifest(
            schemaVersion: 1,
            scope: normalizedScope,
            updatedAt: Date().timeIntervalSince1970,
            myStickers: items
                .filter { !$0.isLocalUploadPlaceholder }
                .map(\.persistentCacheCopy)
        )
        guard let data = try? encoder.encode(manifest) else { return }
        defaults.set(data, forKey: cacheStorageKey(scope: normalizedScope))
    }

    private func cacheStorageKey(scope: String) -> String {
        "im2.ios.stickerManifest.\(Self.stableHash(scope))"
    }

    private static func stableHash(_ raw: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
// WDT_IOS1_STICKER_MANIFEST_DATA_20261111_END

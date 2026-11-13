import CryptoKit
import Foundation

let emojiPickerPreferenceVersion = 1
let emojiPickerMaxRecents = 40

struct EmojiPickerScope: Codable, Equatable, Sendable {
    let product: String
    let appID: String
    let accountID: String
    let tenantID: String
    let imUID: String

    init(product: String, appID: String, accountID: String, tenantID: String, imUID: String) throws {
        guard [product, appID, accountID, tenantID, imUID].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EmojiPickerPreferenceError.invalidScope
        }
        self.product = product
        self.appID = appID
        self.accountID = accountID
        self.tenantID = tenantID
        self.imUID = imUID
    }

    var storageKey: String {
        let source = [product, appID, accountID, tenantID, imUID].joined(separator: "\u{0000}")
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "scope_\(digest)"
    }
}

struct EmojiRecentPreference: Codable, Equatable, Sendable {
    let id: String
    let count: Int
    let lastUsedSequence: Int
}

struct EmojiPickerPreferences: Codable, Equatable, Sendable {
    let version: Int
    let scope: EmojiPickerScope
    var catalogHash: String
    var sequence: Int
    var recents: [EmojiRecentPreference]
    var preferredVariants: [String: String]

    init(scope: EmojiPickerScope, catalogHash: String) {
        version = emojiPickerPreferenceVersion
        self.scope = scope
        self.catalogHash = catalogHash
        sequence = 0
        recents = []
        preferredVariants = [:]
    }

    mutating func recordUse(itemID: String) {
        guard !itemID.isEmpty else { return }
        sequence = max(0, sequence) + 1
        let prior = recents.first(where: { $0.id == itemID })
        let next = EmojiRecentPreference(
            id: itemID,
            count: (prior?.count ?? 0) + 1,
            lastUsedSequence: sequence
        )
        recents = ([next] + recents.filter { $0.id != itemID })
            .sorted {
                $0.lastUsedSequence != $1.lastUsedSequence
                    ? $0.lastUsedSequence > $1.lastUsedSequence
                    : ($0.count != $1.count ? $0.count > $1.count : $0.id < $1.id)
            }
        recents = Array(recents.prefix(emojiPickerMaxRecents))
    }

    func frequentIDs(limit: Int = emojiPickerMaxRecents) -> [String] {
        recents.sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : ($0.lastUsedSequence != $1.lastUsedSequence
                    ? $0.lastUsedSequence > $1.lastUsedSequence
                    : $0.id < $1.id)
        }
        .prefix(max(0, min(limit, emojiPickerMaxRecents)))
        .map(\.id)
    }

    mutating func preferVariant(baseID: String, variantID: String, index: EmojiCatalogIndex) {
        guard let base = index.itemsByID[baseID], base.baseID == nil,
              index.itemsByID[variantID]?.baseID == base.id
        else {
            return
        }
        preferredVariants[base.id] = variantID
    }
}

protocol EmojiPickerPreferenceStore {
    func read(scope: EmojiPickerScope) throws -> Data?
    func write(scope: EmojiPickerScope, data: Data) throws
    func remove(scope: EmojiPickerScope) throws
}

final class UserDefaultsEmojiPickerPreferenceStore: EmojiPickerPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read(scope: EmojiPickerScope) throws -> Data? {
        defaults.data(forKey: "emoji_picker_preferences_v1.\(scope.storageKey)")
    }

    func write(scope: EmojiPickerScope, data: Data) throws {
        defaults.set(data, forKey: "emoji_picker_preferences_v1.\(scope.storageKey)")
    }

    func remove(scope: EmojiPickerScope) throws {
        defaults.removeObject(forKey: "emoji_picker_preferences_v1.\(scope.storageKey)")
    }
}

struct EmojiPickerPreferenceRepository {
    let store: EmojiPickerPreferenceStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load(scope: EmojiPickerScope, catalogHash: String, index: EmojiCatalogIndex) -> EmojiPickerPreferences {
        guard let data = try? store.read(scope: scope),
              var decoded = try? decoder.decode(EmojiPickerPreferences.self, from: data),
              decoded.version == emojiPickerPreferenceVersion,
              decoded.scope == scope
        else {
            return EmojiPickerPreferences(scope: scope, catalogHash: catalogHash)
        }
        decoded.catalogHash = catalogHash
        decoded.sequence = max(0, decoded.sequence)
        var seen = Set<String>()
        decoded.recents = decoded.recents
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted && index.itemsByID[$0.id] != nil }
            .sorted {
                $0.lastUsedSequence != $1.lastUsedSequence
                    ? $0.lastUsedSequence > $1.lastUsedSequence
                    : ($0.count != $1.count ? $0.count > $1.count : $0.id < $1.id)
            }
        decoded.recents = Array(decoded.recents.prefix(emojiPickerMaxRecents))
        decoded.preferredVariants = decoded.preferredVariants.filter { baseID, variantID in
            index.itemsByID[baseID]?.baseID == nil && index.itemsByID[variantID]?.baseID == baseID
        }
        return decoded
    }

    func save(_ preferences: EmojiPickerPreferences) throws {
        try store.write(scope: preferences.scope, data: encoder.encode(preferences))
    }

    func purge(scope: EmojiPickerScope) throws {
        try store.remove(scope: scope)
    }

    func switchScope(
        previousScope: EmojiPickerScope?,
        nextScope: EmojiPickerScope,
        catalogHash: String,
        index: EmojiCatalogIndex
    ) throws -> EmojiPickerPreferences {
        if let previousScope, previousScope != nextScope {
            try store.remove(scope: previousScope)
        }
        return load(scope: nextScope, catalogHash: catalogHash, index: index)
    }
}

enum EmojiPickerPreferenceLifecycle {
    @discardableResult
    static func purgePreviousAuthenticatedScope(
        hasAuthenticatedSession: Bool,
        product: String,
        appID: String,
        accountID: String?,
        tenantID: String?,
        imUID: String?,
        store: EmojiPickerPreferenceStore = UserDefaultsEmojiPickerPreferenceStore()
    ) -> Bool {
        let normalizedAccountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedTenantID = tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIMUID = imUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard hasAuthenticatedSession,
              let scope = try? EmojiPickerScope(
                  product: product,
                  appID: appID,
                  accountID: normalizedAccountID,
                  tenantID: normalizedTenantID,
                  imUID: normalizedIMUID
              ) else {
            return false
        }
        do {
            try EmojiPickerPreferenceRepository(store: store).purge(scope: scope)
            return true
        } catch {
            return false
        }
    }
}

enum EmojiPickerPreferenceError: Error {
    case invalidScope
}

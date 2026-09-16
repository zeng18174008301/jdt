import Combine
import Foundation

enum EmojiPickerCatalogLoadingError: Error {
    case invalidBaseURL
    case invalidResponse
    case responseTooLarge
    case catalogItemCountMismatch
}

enum EmojiPickerCatalogLoadDecision: Equatable, Sendable {
    case attempt
    case useCatalog(EmojiCatalog)
    case useFallback
}

struct EmojiPickerCatalogRuntimeState: Sendable {
    static let initialRetryDelay: TimeInterval = 30
    static let maximumRetryDelay: TimeInterval = 10 * 60

    private var activeScopeKey: String?
    private var activeBaseURL: URL?
    private var cachedCatalog: EmojiCatalog?
    private var attemptInFlight = false
    private var failureCount = 0
    private var retryNotBefore: Date?

    mutating func begin(
        scope: EmojiPickerScope,
        baseURL: URL,
        now: Date = Date()
    ) -> EmojiPickerCatalogLoadDecision {
        activate(scope: scope, baseURL: baseURL)
        if let cachedCatalog {
            return .useCatalog(cachedCatalog)
        }
        if attemptInFlight || retryNotBefore.map({ now < $0 }) == true {
            return .useFallback
        }
        attemptInFlight = true
        return .attempt
    }

    @discardableResult
    mutating func recordSuccess(
        _ catalog: EmojiCatalog,
        scope: EmojiPickerScope,
        baseURL: URL
    ) -> Bool {
        guard matches(scope: scope, baseURL: baseURL), attemptInFlight else {
            return false
        }
        cachedCatalog = catalog
        attemptInFlight = false
        failureCount = 0
        retryNotBefore = nil
        return true
    }

    @discardableResult
    mutating func recordFailure(
        scope: EmojiPickerScope,
        baseURL: URL,
        now: Date = Date()
    ) -> Bool {
        guard matches(scope: scope, baseURL: baseURL), attemptInFlight else {
            return false
        }
        attemptInFlight = false
        cachedCatalog = nil
        failureCount = min(failureCount + 1, 32)
        let exponent = min(max(failureCount - 1, 0), 5)
        let delay = min(
            Self.initialRetryDelay * TimeInterval(1 << exponent),
            Self.maximumRetryDelay
        )
        retryNotBefore = now.addingTimeInterval(delay)
        return true
    }

    mutating func cancelAttempt(scope: EmojiPickerScope, baseURL: URL) {
        guard matches(scope: scope, baseURL: baseURL) else { return }
        attemptInFlight = false
    }

    mutating func reset() {
        activeScopeKey = nil
        activeBaseURL = nil
        cachedCatalog = nil
        attemptInFlight = false
        failureCount = 0
        retryNotBefore = nil
    }

    private mutating func activate(scope: EmojiPickerScope, baseURL: URL) {
        guard !matches(scope: scope, baseURL: baseURL) else { return }
        reset()
        activeScopeKey = scope.storageKey
        activeBaseURL = baseURL
    }

    private func matches(scope: EmojiPickerScope, baseURL: URL) -> Bool {
        activeScopeKey == scope.storageKey && activeBaseURL == baseURL
    }
}

struct EmojiPickerCatalogLoader {
    static let expectedItemCount = 3_944
    static let maximumResponseBytes = 6 * 1_024 * 1_024

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func load(baseURL: URL, locale: String = "zh-Hans") async throws -> EmojiCatalog {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            throw EmojiPickerCatalogLoadingError.invalidBaseURL
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(basePath)/api/im/emojis"
        components.queryItems = [URLQueryItem(name: "locale", value: locale)]
        guard let url = components.url else {
            throw EmojiPickerCatalogLoadingError.invalidBaseURL
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EmojiPickerCatalogLoadingError.invalidResponse
        }
        return try decode(data: data)
    }

    func decode(data: Data, expectedItemCount: Int = Self.expectedItemCount) throws -> EmojiCatalog {
        guard data.count <= Self.maximumResponseBytes else {
            throw EmojiPickerCatalogLoadingError.responseTooLarge
        }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(CatalogEnvelope.self, from: data)
        guard envelope.ok else {
            throw EmojiPickerCatalogLoadingError.invalidResponse
        }
        let items = envelope.data.groups.flatMap(\.items).map(\.catalogItem)
        guard envelope.data.itemCount == expectedItemCount,
              items.count == expectedItemCount else {
            throw EmojiPickerCatalogLoadingError.catalogItemCountMismatch
        }
        return EmojiCatalog(
            schema: envelope.data.schema,
            catalogSchema: envelope.data.catalogSchema,
            catalogVersion: envelope.data.catalogVersion,
            catalogHash: envelope.data.catalogHash,
            emojiVersion: envelope.data.emojiVersion,
            cldrVersion: envelope.data.cldrVersion,
            items: items
        )
    }

    private struct CatalogEnvelope: Decodable {
        let ok: Bool
        let data: CatalogPayload
    }

    private struct CatalogPayload: Decodable {
        let schema: String
        let catalogSchema: String
        let catalogVersion: String
        let catalogHash: String
        let emojiVersion: String
        let cldrVersion: String
        let itemCount: Int
        let groups: [CatalogGroup]

        private enum CodingKeys: String, CodingKey {
            case schema
            case catalogSchema = "catalog_schema"
            case catalogVersion = "catalog_version"
            case catalogHash = "catalog_hash"
            case emojiVersion = "emoji_version"
            case cldrVersion = "cldr_version"
            case itemCount = "item_count"
            case groups
        }
    }

    private struct CatalogGroup: Decodable {
        let items: [CatalogItem]
    }

    private struct CatalogItem: Decodable {
        let id: String
        let emoji: String
        let category: String
        let subgroup: String
        let order: Int
        let name: String
        let nameEn: String
        let nameZhHans: String
        let shortcode: String
        let canonicalShortcode: String
        let keywordsEn: [String]
        let keywordsZhHans: [String]
        let baseID: String?
        let variantIDs: [String]

        private enum CodingKeys: String, CodingKey {
            case id
            case emoji
            case category
            case subgroup
            case order
            case name
            case nameEn = "name_en"
            case nameZhHans = "name_zh_hans"
            case shortcode
            case canonicalShortcode = "canonical_shortcode"
            case keywordsEn = "keywords_en"
            case keywordsZhHans = "keywords_zh_hans"
            case baseID = "base_id"
            case variantIDs = "variant_ids"
        }

        var catalogItem: EmojiCatalogItem {
            EmojiCatalogItem(
                id: id,
                emoji: emoji,
                category: category,
                subgroup: subgroup,
                order: order,
                name: name,
                nameEn: nameEn,
                nameZhHans: nameZhHans,
                shortcode: shortcode,
                canonicalShortcode: canonicalShortcode,
                keywordsEn: keywordsEn,
                keywordsZhHans: keywordsZhHans,
                baseID: baseID,
                variantIDs: variantIDs
            )
        }
    }
}

struct EmojiPickerCategory: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

@MainActor
final class EmojiPickerStoreAdapter: ObservableObject {
    @Published private(set) var session: EmojiPickerSession
    @Published private(set) var preferences: EmojiPickerPreferences
    @Published private(set) var persistenceError: String?
    @Published private(set) var visibleItems: [EmojiCatalogItem]

    private(set) var scope: EmojiPickerScope
    let categories: [EmojiPickerCategory]
    private let index: EmojiCatalogIndex
    private let repository: EmojiPickerPreferenceRepository

    init(
        catalog: EmojiCatalog,
        scope: EmojiPickerScope,
        mode: EmojiPickerMode,
        preferenceStore: EmojiPickerPreferenceStore = UserDefaultsEmojiPickerPreferenceStore()
    ) throws {
        let index = try EmojiCatalogIndex(catalog: catalog)
        let repository = EmojiPickerPreferenceRepository(store: preferenceStore)
        self.index = index
        self.repository = repository
        self.scope = scope
        session = EmojiPickerSession(catalogVersion: catalog.catalogVersion, mode: mode)
        preferences = repository.load(scope: scope, catalogHash: catalog.catalogHash, index: index)
        categories = Self.makeCategories(index: index)
        visibleItems = []
        refreshVisibleItems()
    }

    var catalogVersion: String {
        index.catalog.catalogVersion
    }

    var emptyStateTitle: String {
        if !session.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有找到相关 Emoji"
        }
        if session.category == "recent" {
            return "最近使用的 Emoji 会显示在这里"
        }
        if session.category == "frequent" {
            return "常用 Emoji 会随着使用自动更新"
        }
        return "此分类暂时没有可用 Emoji"
    }

    func open(mode: EmojiPickerMode? = nil) {
        session.open(mode: mode)
    }

    func close() {
        session.close()
    }

    func updateQuery(_ value: String) {
        session.search(String(value.prefix(128)))
        refreshVisibleItems()
    }

    func selectCategory(_ category: String) {
        session.selectCategory(category)
        refreshVisibleItems()
    }

    func variants(for item: EmojiCatalogItem) -> [EmojiCatalogItem] {
        index.variants(for: item.id)
    }

    func isPreferred(_ item: EmojiCatalogItem) -> Bool {
        if let baseID = item.baseID {
            return preferences.preferredVariants[baseID] == item.id
        }
        return !item.variantIDs.isEmpty && preferences.preferredVariants[item.id] == nil
    }

    @discardableResult
    func select(_ item: EmojiCatalogItem) -> EmojiCatalogItem {
        let selected = index.preferredItem(
            for: item.id,
            preferredVariants: preferences.preferredVariants
        ) ?? item
        preferences.recordUse(itemID: selected.baseID ?? selected.id)
        session.focusedItemID = selected.id
        persistPreferences()
        refreshVisibleItems()
        return selected
    }

    @discardableResult
    func selectVariant(_ variant: EmojiCatalogItem) -> EmojiCatalogItem {
        if let baseID = variant.baseID {
            preferences.preferVariant(baseID: baseID, variantID: variant.id, index: index)
        } else {
            preferences.preferredVariants.removeValue(forKey: variant.id)
        }
        preferences.recordUse(itemID: variant.baseID ?? variant.id)
        session.focusedItemID = variant.id
        persistPreferences()
        refreshVisibleItems()
        return variant
    }

    func switchScope(to nextScope: EmojiPickerScope) {
        guard nextScope != scope else { return }
        do {
            preferences = try repository.switchScope(
                previousScope: scope,
                nextScope: nextScope,
                catalogHash: index.catalog.catalogHash,
                index: index
            )
            scope = nextScope
            session.clearIdentity()
            persistenceError = nil
            refreshVisibleItems()
        } catch {
            scope = nextScope
            preferences = EmojiPickerPreferences(
                scope: nextScope,
                catalogHash: index.catalog.catalogHash
            )
            session.clearIdentity()
            refreshVisibleItems()
            persistenceError = "Emoji 偏好切换失败"
        }
    }

    func clearIdentity() {
        do {
            try repository.purge(scope: scope)
            persistenceError = nil
        } catch {
            persistenceError = "Emoji 偏好清理失败"
        }
        preferences = EmojiPickerPreferences(
            scope: scope,
            catalogHash: index.catalog.catalogHash
        )
        session.clearIdentity()
        refreshVisibleItems()
    }

    private func persistPreferences() {
        do {
            try repository.save(preferences)
            persistenceError = nil
        } catch {
            persistenceError = "Emoji 偏好保存失败"
        }
    }

    private func refreshVisibleItems() {
        let source: [EmojiCatalogItem]
        if !session.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = index.search(session.query, includeVariants: false, limit: 500)
        } else {
            switch session.category {
            case "recent":
                source = preferences.recents.compactMap { index.itemsByID[$0.id] }
            case "frequent":
                source = preferences.frequentIDs().compactMap { index.itemsByID[$0] }
            default:
                source = index.catalog.items.filter {
                    $0.baseID == nil && $0.category == session.category
                }
            }
        }
        visibleItems = source.compactMap {
            index.preferredItem(for: $0.id, preferredVariants: preferences.preferredVariants)
        }
    }

    private static func makeCategories(index: EmojiCatalogIndex) -> [EmojiPickerCategory] {
        var seen = Set<String>()
        let catalogCategories = index.catalog.items
            .filter { $0.baseID == nil && seen.insert($0.category).inserted }
            .map {
                EmojiPickerCategory(
                    id: $0.category,
                    title: localizedCategoryTitle($0.category)
                )
            }
        return [
            EmojiPickerCategory(id: "recent", title: "最近使用"),
            EmojiPickerCategory(id: "frequent", title: "常用"),
        ] + catalogCategories
    }

    private static func localizedCategoryTitle(_ category: String) -> String {
        switch category.lowercased() {
        case "smileys & emotion", "smileys-emotion", "smileys_and_emotion":
            return "笑脸与情感"
        case "people & body", "people-body", "people_and_body":
            return "人物与身体"
        case "animals & nature", "animals-nature", "animals_and_nature":
            return "动物与自然"
        case "food & drink", "food-drink", "food_and_drink":
            return "食物与饮品"
        case "travel & places", "travel-places", "travel_and_places":
            return "旅行与地点"
        case "activities":
            return "活动"
        case "objects":
            return "物品"
        case "symbols":
            return "符号"
        case "flags":
            return "旗帜"
        default:
            return category
        }
    }
}

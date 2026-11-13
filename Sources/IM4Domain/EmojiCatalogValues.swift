import Foundation

public struct EmojiCatalogItem: Codable, Equatable, Sendable {
    public let id: String
    public let emoji: String
    public let category: String
    public let subgroup: String
    public let order: Int
    public let name: String
    public let nameEn: String
    public let nameZhHans: String
    public let shortcode: String
    public let canonicalShortcode: String
    public let keywordsEn: [String]
    public let keywordsZhHans: [String]
    public let baseID: String?
    public let variantIDs: [String]

    public init(id: String,
        emoji: String,
        category: String,
        subgroup: String,
        order: Int,
        name: String,
        nameEn: String,
        nameZhHans: String,
        shortcode: String,
        canonicalShortcode: String,
        keywordsEn: [String],
        keywordsZhHans: [String],
        baseID: String? = nil,
        variantIDs: [String]) {
        self.id = id
        self.emoji = emoji
        self.category = category
        self.subgroup = subgroup
        self.order = order
        self.name = name
        self.nameEn = nameEn
        self.nameZhHans = nameZhHans
        self.shortcode = shortcode
        self.canonicalShortcode = canonicalShortcode
        self.keywordsEn = keywordsEn
        self.keywordsZhHans = keywordsZhHans
        self.baseID = baseID
        self.variantIDs = variantIDs
    }
}

public struct EmojiCatalog: Codable, Equatable, Sendable {
    public let schema: String
    public let catalogSchema: String
    public let catalogVersion: String
    public let catalogHash: String
    public let emojiVersion: String
    public let cldrVersion: String
    public let items: [EmojiCatalogItem]

    public init(schema: String,
        catalogSchema: String,
        catalogVersion: String,
        catalogHash: String,
        emojiVersion: String,
        cldrVersion: String,
        items: [EmojiCatalogItem]) {
        self.schema = schema
        self.catalogSchema = catalogSchema
        self.catalogVersion = catalogVersion
        self.catalogHash = catalogHash
        self.emojiVersion = emojiVersion
        self.cldrVersion = cldrVersion
        self.items = items
    }
}


public let emojiCatalogProjectionSchema = "im_emoji_catalog.v2"
public let unicodeEmojiCatalogSchema = "unicode_emoji_catalog.v1"
public let frozenEmojiCatalogVersion = "unicode-emoji-17.0-cldr-48-5df48d2f7cb3"
public let frozenEmojiCatalogHash = "sha256:5df48d2f7cb3ee9cd61b86a91e3c2f9627a63dfa3129b923be194c4b6ccc9c35"

public struct EmojiCatalogIndex: Sendable {
    public let catalog: EmojiCatalog
    public let itemsByID: [String: EmojiCatalogItem]
    public let itemsByEmoji: [String: EmojiCatalogItem]
    private let records: [SearchRecord]

    private struct SearchRecord: Sendable {
        let item: EmojiCatalogItem
        let terms: [String]
    }

    public init(catalog: EmojiCatalog) throws {
        guard catalog.schema == emojiCatalogProjectionSchema,
              catalog.catalogSchema == unicodeEmojiCatalogSchema,
              catalog.catalogVersion == frozenEmojiCatalogVersion,
              catalog.catalogHash == frozenEmojiCatalogHash,
              catalog.emojiVersion == "17.0",
              catalog.cldrVersion == "48"
        else {
            throw EmojiPickerCoreError.invalidCatalogIdentity
        }
        var byID: [String: EmojiCatalogItem] = [:]
        var byEmoji: [String: EmojiCatalogItem] = [:]
        for item in catalog.items {
            guard byID[item.id] == nil, byEmoji[item.emoji] == nil else {
                throw EmojiPickerCoreError.duplicateCatalogItem
            }
            byID[item.id] = item
            byEmoji[item.emoji] = item
        }
        for item in catalog.items {
            guard !item.id.isEmpty, !item.emoji.isEmpty, !item.category.isEmpty else {
                throw EmojiPickerCoreError.invalidCatalogItem
            }
            if let baseID = item.baseID, byID[baseID] == nil {
                throw EmojiPickerCoreError.invalidVariantEdge
            }
            if item.variantIDs.contains(where: { byID[$0]?.baseID != item.id }) {
                throw EmojiPickerCoreError.invalidVariantEdge
            }
        }
        self.catalog = catalog
        itemsByID = byID
        itemsByEmoji = byEmoji
        records = catalog.items.map { item in
            let terms = [
                item.emoji,
                item.id,
                item.shortcode,
                item.canonicalShortcode,
                item.name,
                item.nameEn,
                item.nameZhHans,
                item.category,
                item.subgroup,
            ]
                + item.keywordsEn
                + item.keywordsZhHans
            return SearchRecord(
                item: item,
                terms: terms.map(normalizeEmojiSearchText).filter { !$0.isEmpty }
            )
        }
    }

    public func search(
        _ rawQuery: String,
        category: String? = nil,
        includeVariants: Bool = false,
        limit: Int = 200
    ) -> [EmojiCatalogItem] {
        let rawBounded = String(rawQuery.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
        let query = normalizeEmojiSearchText(rawBounded)
        let tokens = query.split(separator: " ").prefix(8).map(String.init)
        return records.compactMap { record -> (Int, EmojiCatalogItem)? in
            if let category, !category.isEmpty, record.item.category != category { return nil }
            if !includeVariants, record.item.baseID != nil { return nil }
            let score: Int?
            if query == normalizeEmojiSearchText(record.item.emoji) {
                score = 0
            } else if query == normalizeEmojiSearchText(record.item.shortcode)
                        || query == normalizeEmojiSearchText(record.item.canonicalShortcode) {
                score = 1
            } else if query == normalizeEmojiSearchText(record.item.name)
                        || query == normalizeEmojiSearchText(record.item.nameEn)
                        || query == normalizeEmojiSearchText(record.item.nameZhHans) {
                score = 2
            } else if tokens.allSatisfy({ token in record.terms.contains(where: { $0.contains(token) }) }) {
                score = record.terms.contains(where: { $0.hasPrefix(query) }) ? 3 : 4
            } else {
                score = nil
            }
            return score.map { ($0, record.item) }
        }
        .sorted {
            $0.0 != $1.0
                ? $0.0 < $1.0
                : ($0.1.order != $1.1.order ? $0.1.order < $1.1.order : $0.1.id < $1.1.id)
        }
        .prefix(max(1, min(limit, 500)))
        .map(\.1)
    }

    public func variants(for itemID: String) -> [EmojiCatalogItem] {
        guard let item = itemsByID[itemID] else {
            return []
        }
        let base = item.baseID.flatMap { itemsByID[$0] } ?? item
        return [base] + base.variantIDs.compactMap { itemsByID[$0] }
    }

    public func preferredItem(for itemID: String, preferredVariants: [String: String]) -> EmojiCatalogItem? {
        guard let item = itemsByID[itemID] else {
            return nil
        }
        let base = item.baseID.flatMap { itemsByID[$0] } ?? item
        guard let preferredID = preferredVariants[base.id],
              let preferred = itemsByID[preferredID],
              preferred.baseID == base.id
        else {
            return base
        }
        return preferred
    }
}

public enum EmojiPickerCoreError: Error {
    case invalidCatalogIdentity
    case duplicateCatalogItem
    case invalidCatalogItem
    case invalidVariantEdge
}

func normalizeEmojiSearchText(_ value: String) -> String {
    let compatibility = value.precomposedStringWithCompatibilityMapping
    let safeScalars = compatibility.unicodeScalars.map { scalar -> String in
        let codepoint = scalar.value
        let bidiControl = codepoint == 0x061C
            || codepoint == 0x200E
            || codepoint == 0x200F
            || (0x202A ... 0x202E).contains(codepoint)
            || (0x2066 ... 0x2069).contains(codepoint)
        let emojiFormat = codepoint == 0x200D || (0xE0020 ... 0xE007F).contains(codepoint)
        if bidiControl || scalar.properties.generalCategory == .control
            || (scalar.properties.generalCategory == .format && !emojiFormat) {
            return " "
        }
        return String(scalar)
    }.joined()
    return safeScalars
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

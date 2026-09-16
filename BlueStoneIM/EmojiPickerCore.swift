import Foundation

let emojiCatalogProjectionSchema = "im_emoji_catalog.v2"
let unicodeEmojiCatalogSchema = "unicode_emoji_catalog.v1"
let frozenEmojiCatalogVersion = "unicode-emoji-17.0-cldr-48-5df48d2f7cb3"
let frozenEmojiCatalogHash = "sha256:5df48d2f7cb3ee9cd61b86a91e3c2f9627a63dfa3129b923be194c4b6ccc9c35"

struct EmojiCatalogItem: Codable, Equatable, Sendable {
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
}

struct EmojiCatalog: Codable, Equatable, Sendable {
    let schema: String
    let catalogSchema: String
    let catalogVersion: String
    let catalogHash: String
    let emojiVersion: String
    let cldrVersion: String
    let items: [EmojiCatalogItem]
}

struct EmojiCatalogIndex: Sendable {
    let catalog: EmojiCatalog
    let itemsByID: [String: EmojiCatalogItem]
    let itemsByEmoji: [String: EmojiCatalogItem]
    private let records: [SearchRecord]

    private struct SearchRecord: Sendable {
        let item: EmojiCatalogItem
        let terms: [String]
    }

    init(catalog: EmojiCatalog) throws {
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

    func search(
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

    func variants(for itemID: String) -> [EmojiCatalogItem] {
        guard let item = itemsByID[itemID] else {
            return []
        }
        let base = item.baseID.flatMap { itemsByID[$0] } ?? item
        return [base] + base.variantIDs.compactMap { itemsByID[$0] }
    }

    func preferredItem(for itemID: String, preferredVariants: [String: String]) -> EmojiCatalogItem? {
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

enum EmojiPickerCoreError: Error {
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

enum EmojiPickerMode: String, Codable, Sendable {
    case composer
    case reaction
}

struct EmojiPickerSession: Equatable, Sendable {
    let catalogVersion: String
    var mode: EmojiPickerMode
    var isOpen = false
    var query = ""
    var category = "recent"
    var focusedItemID = ""
    var scrollOffsets: [String: Double] = [:]

    private var viewKey: String {
        query.isEmpty ? "category:\(category)" : "search:\(query)"
    }

    mutating func open(mode nextMode: EmojiPickerMode? = nil) {
        mode = nextMode ?? mode
        isOpen = true
    }

    mutating func close() {
        isOpen = false
        focusedItemID = ""
    }

    mutating func search(_ value: String) {
        query = value
        focusedItemID = ""
    }

    mutating func selectCategory(_ value: String) {
        query = ""
        category = value.isEmpty ? "recent" : value
        focusedItemID = ""
    }

    mutating func saveScroll(_ offset: Double) {
        scrollOffsets[viewKey] = max(0, offset)
    }

    var restoredScroll: Double {
        max(0, scrollOffsets[viewKey] ?? 0)
    }

    mutating func clearIdentity() {
        self = EmojiPickerSession(catalogVersion: catalogVersion, mode: mode)
    }
}

struct EmojiInsertionResult: Equatable, Sendable {
    let text: String
    let selectionStart: Int
    let selectionEnd: Int
}

func insertEmojiAtSelection(
    text: String,
    selectionStart: Int,
    selectionEnd: Int,
    emoji: String
) -> EmojiInsertionResult {
    var boundaries = [0]
    var offset = 0
    for character in text {
        offset += String(character).utf16.count
        boundaries.append(offset)
    }
    let rawStart = max(0, min(selectionStart, text.utf16.count))
    let rawEnd = max(rawStart, min(selectionEnd, text.utf16.count))
    let start = boundaries.last(where: { $0 <= rawStart }) ?? 0
    let end = boundaries.first(where: { $0 >= rawEnd }) ?? text.utf16.count
    let startIndex = String.Index(utf16Offset: start, in: text)
    let endIndex = String.Index(utf16Offset: end, in: text)
    let next = String(text[..<startIndex]) + emoji + String(text[endIndex...])
    let caret = start + emoji.utf16.count
    return EmojiInsertionResult(text: next, selectionStart: caret, selectionEnd: caret)
}

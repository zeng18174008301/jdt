import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("task024 emoji picker core failed: \(message)\n", stderr)
        exit(1)
    }
}

private func rejectsDuplicateCatalog(_ catalog: EmojiCatalog) -> Bool {
    do {
        _ = try EmojiCatalogIndex(catalog: catalog)
        return false
    } catch EmojiPickerCoreError.duplicateCatalogItem {
        return true
    } catch {
        return false
    }
}

private final class MemoryStore: EmojiPickerPreferenceStore {
    var values: [String: Data] = [:]

    func read(scope: EmojiPickerScope) throws -> Data? {
        values[scope.storageKey]
    }

    func write(scope: EmojiPickerScope, data: Data) throws {
        values[scope.storageKey] = data
    }

    func remove(scope: EmojiPickerScope) throws {
        values.removeValue(forKey: scope.storageKey)
    }
}

@main
private enum Task024EmojiPickerCoreSmoke {
    static func main() throws {
        let base = EmojiCatalogItem(
            id: "1f44d",
            emoji: "👍",
            category: "people_and_body",
            subgroup: "hand_fingers_closed",
            order: 0,
            name: "拇指向上",
            nameEn: "thumbs up",
            nameZhHans: "拇指向上",
            shortcode: "thumbs_up",
            canonicalShortcode: ":thumbs_up:",
            keywordsEn: ["like", "yes"],
            keywordsZhHans: ["赞", "同意"],
            baseID: nil,
            variantIDs: ["1f44d-1f3fd"]
        )
        let variant = EmojiCatalogItem(
            id: "1f44d-1f3fd",
            emoji: "👍🏽",
            category: base.category,
            subgroup: base.subgroup,
            order: 1,
            name: base.name,
            nameEn: base.nameEn,
            nameZhHans: base.nameZhHans,
            shortcode: "thumbs_up_medium_skin_tone",
            canonicalShortcode: ":thumbs_up_medium_skin_tone:",
            keywordsEn: base.keywordsEn,
            keywordsZhHans: base.keywordsZhHans,
            baseID: base.id,
            variantIDs: []
        )
        let heart = EmojiCatalogItem(
            id: "2764-fe0f",
            emoji: "❤️",
            category: "smileys_and_emotion",
            subgroup: "heart",
            order: 2,
            name: "红心",
            nameEn: "red heart",
            nameZhHans: "红心",
            shortcode: "red_heart",
            canonicalShortcode: ":red_heart:",
            keywordsEn: [],
            keywordsZhHans: [],
            baseID: nil,
            variantIDs: []
        )
        let catalog = EmojiCatalog(
            schema: emojiCatalogProjectionSchema,
            catalogSchema: unicodeEmojiCatalogSchema,
            catalogVersion: frozenEmojiCatalogVersion,
            catalogHash: frozenEmojiCatalogHash,
            emojiVersion: "17.0",
            cldrVersion: "48",
            items: [base, variant, heart]
        )
        let index = try EmojiCatalogIndex(catalog: catalog)
        let duplicateID = EmojiCatalogItem(
            id: base.id,
            emoji: "✅",
            category: base.category,
            subgroup: base.subgroup,
            order: 3,
            name: "复选标记按钮",
            nameEn: "check mark button",
            nameZhHans: "复选标记按钮",
            shortcode: "check_mark_button",
            canonicalShortcode: ":check_mark_button:",
            keywordsEn: [],
            keywordsZhHans: [],
            baseID: nil,
            variantIDs: []
        )
        let duplicateEmoji = EmojiCatalogItem(
            id: "duplicate-emoji",
            emoji: base.emoji,
            category: base.category,
            subgroup: base.subgroup,
            order: 4,
            name: base.name,
            nameEn: base.nameEn,
            nameZhHans: base.nameZhHans,
            shortcode: "duplicate_emoji",
            canonicalShortcode: ":duplicate_emoji:",
            keywordsEn: [],
            keywordsZhHans: [],
            baseID: nil,
            variantIDs: []
        )
        require(
            rejectsDuplicateCatalog(
                EmojiCatalog(
                    schema: catalog.schema,
                    catalogSchema: catalog.catalogSchema,
                    catalogVersion: catalog.catalogVersion,
                    catalogHash: catalog.catalogHash,
                    emojiVersion: catalog.emojiVersion,
                    cldrVersion: catalog.cldrVersion,
                    items: [base, duplicateID]
                )
            ),
            "duplicate id rejection"
        )
        require(
            rejectsDuplicateCatalog(
                EmojiCatalog(
                    schema: catalog.schema,
                    catalogSchema: catalog.catalogSchema,
                    catalogVersion: catalog.catalogVersion,
                    catalogHash: catalog.catalogHash,
                    emojiVersion: catalog.emojiVersion,
                    cldrVersion: catalog.cldrVersion,
                    items: [base, duplicateEmoji]
                )
            ),
            "duplicate emoji rejection"
        )
        require(index.search("thumbs up").first?.emoji == "👍", "English search")
        require(index.search("拇指向上").first?.emoji == "👍", "Chinese search")
        require(index.search("\u{202E} THUMBS\u{0000} UP").first?.emoji == "👍", "bidi/control search")
        require(index.search("\u{2060}👍").first?.emoji == "👍", "format-control emoji search")
        require(index.search("").map(\.emoji) == ["👍", "❤️"], "root grid variant filtering")
        require(index.variants(for: base.id).map(\.emoji) == ["👍", "👍🏽"], "variant edge")
        require(
            index.preferredItem(for: base.id, preferredVariants: [base.id: variant.id])?.emoji == "👍🏽",
            "preferred variant"
        )

        var session = EmojiPickerSession(catalogVersion: frozenEmojiCatalogVersion, mode: .reaction)
        session.open()
        session.saveScroll(120)
        session.search("thumb")
        session.saveScroll(80)
        require(session.restoredScroll == 80, "search scroll")
        session.selectCategory("recent")
        require(session.restoredScroll == 120, "category scroll")
        session.clearIdentity()
        require(!session.isOpen && session.scrollOffsets.isEmpty, "identity transient purge")

        require(
            insertEmojiAtSelection(text: "A👩‍💻B", selectionStart: 3, selectionEnd: 4, emoji: "👍🏽")
                == EmojiInsertionResult(text: "A👍🏽B", selectionStart: 5, selectionEnd: 5),
            "ZWJ grapheme insertion"
        )

        let scopeA = try EmojiPickerScope(
            product: "ios",
            appID: "app1",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "uid-a"
        )
        let scopeB = try EmojiPickerScope(
            product: "ios",
            appID: "app2",
            accountID: "account-b",
            tenantID: "tenant-b",
            imUID: "uid-b"
        )
        var preferences = EmojiPickerPreferences(scope: scopeA, catalogHash: frozenEmojiCatalogHash)
        for position in 0 ..< 45 {
            preferences.recordUse(itemID: position == 44 ? base.id : "item-\(position)")
        }
        preferences.recordUse(itemID: base.id)
        preferences.preferVariant(baseID: base.id, variantID: variant.id, index: index)
        require(preferences.recents.count == 40, "recent bound")
        require(preferences.frequentIDs(limit: 1) == [base.id], "frequent order")

        let store = MemoryStore()
        let repository = EmojiPickerPreferenceRepository(store: store)
        try repository.save(preferences)
        let loaded = repository.load(scope: scopeA, catalogHash: frozenEmojiCatalogHash, index: index)
        require(loaded.recents.count == 1, "catalog upgrade pruning")
        require(loaded.preferredVariants[base.id] == variant.id, "preferred persistence")
        let next = try repository.switchScope(
            previousScope: scopeA,
            nextScope: scopeB,
            catalogHash: frozenEmojiCatalogHash,
            index: index
        )
        require(next.recents.isEmpty, "cross-account isolation")
        require(store.values[scopeA.storageKey] == nil, "old scope purge")
        try repository.purge(scope: scopeB)
        require(store.values[scopeB.storageKey] == nil, "logout purge")

        print("task024 emoji picker core ok")
    }
}

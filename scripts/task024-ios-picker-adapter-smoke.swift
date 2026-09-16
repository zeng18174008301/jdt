import Foundation

private enum SmokeFailure: Error {
    case assertion(String)
    case storage
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw SmokeFailure.assertion(message)
    }
}

private final class MemoryEmojiPickerStore: EmojiPickerPreferenceStore {
    private(set) var values: [String: Data] = [:]
    var removeFails = false

    func read(scope: EmojiPickerScope) throws -> Data? {
        values[scope.storageKey]
    }

    func write(scope: EmojiPickerScope, data: Data) throws {
        values[scope.storageKey] = data
    }

    func remove(scope: EmojiPickerScope) throws {
        if removeFails {
            throw SmokeFailure.storage
        }
        values.removeValue(forKey: scope.storageKey)
    }
}

@main
private struct EmojiPickerAdapterSmoke {
    @MainActor
    static func main() throws {
        let wavingBase = EmojiCatalogItem(
            id: "1f44b",
            emoji: "👋",
            category: "People & Body",
            subgroup: "hand-fingers-open",
            order: 0,
            name: "挥手",
            nameEn: "waving hand",
            nameZhHans: "挥手",
            shortcode: ":wave:",
            canonicalShortcode: ":waving_hand:",
            keywordsEn: ["wave", "hello"],
            keywordsZhHans: ["挥手", "你好"],
            baseID: nil,
            variantIDs: ["1f44b-1f3fb", "1f44b-1f3fd"]
        )
        let wavingLightVariant = EmojiCatalogItem(
            id: "1f44b-1f3fb",
            emoji: "👋🏻",
            category: "People & Body",
            subgroup: "hand-fingers-open",
            order: 1,
            name: "挥手：浅肤色",
            nameEn: "waving hand: light skin tone",
            nameZhHans: "挥手：浅肤色",
            shortcode: ":wave_tone1:",
            canonicalShortcode: ":waving_hand_light_skin_tone:",
            keywordsEn: ["wave", "hello", "skin tone"],
            keywordsZhHans: ["挥手", "你好", "肤色"],
            baseID: wavingBase.id,
            variantIDs: []
        )
        let wavingVariant = EmojiCatalogItem(
            id: "1f44b-1f3fd",
            emoji: "👋🏽",
            category: "People & Body",
            subgroup: "hand-fingers-open",
            order: 2,
            name: "挥手：中等肤色",
            nameEn: "waving hand: medium skin tone",
            nameZhHans: "挥手：中等肤色",
            shortcode: ":wave_tone3:",
            canonicalShortcode: ":waving_hand_medium_skin_tone:",
            keywordsEn: ["wave", "hello", "skin tone"],
            keywordsZhHans: ["挥手", "你好", "肤色"],
            baseID: wavingBase.id,
            variantIDs: []
        )
        let rocket = EmojiCatalogItem(
            id: "1f680",
            emoji: "🚀",
            category: "Travel & Places",
            subgroup: "transport-air",
            order: 3,
            name: "火箭",
            nameEn: "rocket",
            nameZhHans: "火箭",
            shortcode: ":rocket:",
            canonicalShortcode: ":rocket:",
            keywordsEn: ["rocket", "space"],
            keywordsZhHans: ["火箭", "太空"],
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
            items: [wavingBase, wavingLightVariant, wavingVariant, rocket]
        )
        func serverItem(_ item: EmojiCatalogItem) -> [String: Any] {
            [
                "id": item.id,
                "emoji": item.emoji,
                "category": item.category,
                "subgroup": item.subgroup,
                "order": item.order,
                "name": item.name,
                "name_en": item.nameEn,
                "name_zh_hans": item.nameZhHans,
                "shortcode": item.shortcode,
                "canonical_shortcode": item.canonicalShortcode,
                "keywords_en": item.keywordsEn,
                "keywords_zh_hans": item.keywordsZhHans,
                "base_id": (item.baseID as Any?) ?? NSNull(),
                "variant_ids": item.variantIDs,
            ]
        }
        let catalogEnvelope: [String: Any] = [
            "ok": true,
            "data": [
                "schema": emojiCatalogProjectionSchema,
                "catalog_schema": unicodeEmojiCatalogSchema,
                "catalog_version": frozenEmojiCatalogVersion,
                "catalog_hash": frozenEmojiCatalogHash,
                "emoji_version": "17.0",
                "cldr_version": "48",
                "item_count": catalog.items.count,
                "groups": [
                    ["items": catalog.items.map(serverItem)]
                ],
            ],
        ]
        let catalogData = try JSONSerialization.data(withJSONObject: catalogEnvelope)
        let decodedCatalog = try EmojiPickerCatalogLoader().decode(
            data: catalogData,
            expectedItemCount: catalog.items.count
        )
        try require(decodedCatalog == catalog, "server catalog projection did not decode deterministically")

        let firstScope = try EmojiPickerScope(
            product: "ios",
            appID: "app1",
            accountID: "account-a",
            tenantID: "tenant-a",
            imUID: "user-a"
        )
        let secondScope = try EmojiPickerScope(
            product: "ios",
            appID: "app2",
            accountID: "account-b",
            tenantID: "tenant-b",
            imUID: "user-b"
        )
        let memoryStore = MemoryEmojiPickerStore()
        let adapter = try EmojiPickerStoreAdapter(
            catalog: catalog,
            scope: firstScope,
            mode: .composer,
            preferenceStore: memoryStore
        )

        try require(adapter.catalogVersion == frozenEmojiCatalogVersion, "catalog identity drifted")
        try require(adapter.categories.map(\.title).contains("人物与身体"), "category localization missing")
        try require(adapter.visibleItems.isEmpty, "recent state should start empty")

        adapter.selectCategory("People & Body")
        try require(adapter.visibleItems == [wavingBase], "base category projection is not deterministic")

        let selectedLightVariant = adapter.selectVariant(wavingLightVariant)
        try require(selectedLightVariant == wavingLightVariant, "first variant selection returned the wrong item")
        let selectedVariant = adapter.selectVariant(wavingVariant)
        try require(selectedVariant == wavingVariant, "second variant selection returned the wrong item")
        try require(adapter.preferences.preferredVariants[wavingBase.id] == wavingVariant.id, "sticky variant was not recorded")
        try require(adapter.preferences.recents.map(\.id) == [wavingBase.id], "variant recents were not normalized to the root id")
        try require(memoryStore.values[firstScope.storageKey] != nil, "scoped preferences were not persisted")

        let selectedBase = adapter.selectVariant(wavingBase)
        try require(selectedBase == wavingBase, "default variant selection returned the wrong item")
        try require(adapter.preferences.preferredVariants[wavingBase.id] == nil, "default variant did not clear the sticky variant")
        try require(adapter.preferences.recents.map(\.id) == [wavingBase.id], "default selection duplicated the recent root")
        try require(adapter.preferences.frequentIDs() == [wavingBase.id], "variant frequency duplicated the root")

        _ = adapter.selectVariant(wavingVariant)
        adapter.selectCategory("recent")
        try require(adapter.visibleItems.first == wavingVariant, "recent projection lost the preferred variant")

        adapter.updateQuery("waving")
        try require(adapter.visibleItems.first == wavingVariant, "English search did not resolve the preferred variant")
        adapter.updateQuery("火箭")
        try require(adapter.visibleItems == [rocket], "Chinese search returned an unexpected result")

        adapter.switchScope(to: secondScope)
        try require(memoryStore.values[firstScope.storageKey] == nil, "previous account preferences were not purged")
        try require(adapter.visibleItems.isEmpty, "account switch leaked recent state")

        _ = adapter.select(rocket)
        try require(memoryStore.values[secondScope.storageKey] != nil, "new account preferences were not persisted")
        adapter.clearIdentity()
        try require(memoryStore.values[secondScope.storageKey] == nil, "logout cleanup did not purge scoped preferences")
        try require(adapter.visibleItems.isEmpty, "logout cleanup retained recent state")

        let failingStore = MemoryEmojiPickerStore()
        let failClosedAdapter = try EmojiPickerStoreAdapter(
            catalog: catalog,
            scope: firstScope,
            mode: .reaction,
            preferenceStore: failingStore
        )
        _ = failClosedAdapter.select(wavingBase)
        failingStore.removeFails = true
        failClosedAdapter.switchScope(to: secondScope)
        try require(failClosedAdapter.scope == secondScope, "failed purge retained the previous in-memory scope")
        try require(failClosedAdapter.preferences.scope == secondScope, "failed purge retained previous preferences")
        try require(failClosedAdapter.visibleItems.isEmpty, "failed purge leaked previous recents")
        try require(failClosedAdapter.persistenceError != nil, "failed purge did not expose a storage error")

        _ = failClosedAdapter.select(rocket)
        failClosedAdapter.clearIdentity()
        try require(failClosedAdapter.preferences.recents.isEmpty, "failed logout purge retained recents in memory")
        try require(failClosedAdapter.visibleItems.isEmpty, "failed logout purge retained visible items")

        let lifecycleStore = MemoryEmojiPickerStore()
        let lifecycleRepository = EmojiPickerPreferenceRepository(store: lifecycleStore)
        var lifecyclePreferences = EmojiPickerPreferences(
            scope: firstScope,
            catalogHash: frozenEmojiCatalogHash
        )
        lifecyclePreferences.recordUse(itemID: wavingBase.id)
        try lifecycleRepository.save(lifecyclePreferences)
        let rawWhitespaceScope = try EmojiPickerScope(
            product: firstScope.product,
            appID: firstScope.appID,
            accountID: " \n\(firstScope.accountID)\t",
            tenantID: "\t\(firstScope.tenantID)\n",
            imUID: " \(firstScope.imUID) \n"
        )
        try lifecycleRepository.save(
            EmojiPickerPreferences(
                scope: rawWhitespaceScope,
                catalogHash: frozenEmojiCatalogHash
            )
        )
        try require(
            !EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(
                hasAuthenticatedSession: false,
                product: firstScope.product,
                appID: firstScope.appID,
                accountID: firstScope.accountID,
                tenantID: firstScope.tenantID,
                imUID: firstScope.imUID,
                store: lifecycleStore
            ),
            "unauthenticated lifecycle purge should not claim a scope"
        )
        try require(
            lifecycleStore.values[firstScope.storageKey] != nil,
            "unauthenticated lifecycle purge removed a stored scope"
        )
        try require(
            EmojiPickerPreferenceLifecycle.purgePreviousAuthenticatedScope(
                hasAuthenticatedSession: true,
                product: firstScope.product,
                appID: firstScope.appID,
                accountID: rawWhitespaceScope.accountID,
                tenantID: rawWhitespaceScope.tenantID,
                imUID: rawWhitespaceScope.imUID,
                store: lifecycleStore
            ),
            "authenticated lifecycle purge did not resolve the previous scope"
        )
        try require(
            lifecycleStore.values[firstScope.storageKey] == nil,
            "authenticated lifecycle purge retained previous preferences"
        )
        try require(
            lifecycleStore.values[rawWhitespaceScope.storageKey] != nil,
            "authenticated lifecycle purge addressed the raw-whitespace key"
        )

        print("TASK024 iOS emoji picker adapter smoke passed")
    }
}

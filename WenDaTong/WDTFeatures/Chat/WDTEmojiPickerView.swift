import SwiftUI
import IM4Domain
import IM4Features

struct EmojiPickerView: View {
    @ObservedObject var store: EmojiPickerStoreAdapter
    let onSelect: (EmojiCatalogItem) -> Void
    var onClose: (() -> Void)?
    var preferredHeight: CGFloat = 268

    var body: some View {
        EmojiPickerContent(presentation: store.presentationState,
            input: .init(categories: store.categories, visibleItems: store.visibleItems, emptyStateTitle: store.emptyStateTitle),
            updateQuery: store.updateQuery, selectCategory: store.selectCategory,
            variants: { store.variants(for: $0) }, isPreferred: store.isPreferred,
            onSelect: onSelect, select: store.select, selectVariant: store.selectVariant,
            onOpen: { store.open() }, onDisappearPicker: store.close,
            onClose: onClose, preferredHeight: preferredHeight)
    }
}

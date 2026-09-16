import SwiftUI
import UIKit

struct EmojiPickerView: View {
    @ObservedObject var store: EmojiPickerStoreAdapter
    let onSelect: (EmojiCatalogItem) -> Void
    var onClose: (() -> Void)?
    var preferredHeight: CGFloat = 268

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 46
    @State private var variantTarget: EmojiCatalogItem?

    private var gridColumns: [GridItem] {
        let minimum = max(44, tileSize)
        return [GridItem(.adaptive(minimum: minimum, maximum: minimum + 14), spacing: 8)]
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            searchField
            categoryRail
            emojiGrid
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .frame(height: preferredHeight)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unicode_emoji_picker")
        .onAppear {
            store.open()
        }
        .onDisappear {
            store.close()
        }
        .confirmationDialog(
            variantDialogTitle,
            isPresented: variantDialogBinding,
            titleVisibility: .visible
        ) {
            if let target = variantTarget {
                ForEach(store.variants(for: target), id: \.id) { variant in
                    Button {
                        selectVariant(variant)
                    } label: {
                        Text("\(variant.emoji) \(localizedName(for: variant))")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择后会记住这个变体；也可在任意 Emoji 的快捷菜单中再次更改。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.session.mode == .reaction ? "选择表情回应" : "Emoji")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Unicode 17 · 原生字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let onClose {
                Button {
                    store.close()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭 Emoji 选择器")
                .accessibilityIdentifier("unicode_emoji_picker_close")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "搜索中文、English 或 :shortcode:",
                text: Binding(
                    get: { store.session.query },
                    set: { query in
                        store.updateQuery(query)
                    }
                )
            )
            .focused($searchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.search)
            .accessibilityLabel("搜索 Emoji")
            .accessibilityHint("可输入中文名、英文名、关键词或短代码")
            .accessibilityIdentifier("unicode_emoji_picker_search")

            if !store.session.query.isEmpty {
                Button {
                    store.updateQuery("")
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除 Emoji 搜索")
                .accessibilityIdentifier("unicode_emoji_picker_search_clear")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, store.session.query.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
    }

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.categories) { category in
                    let selected = store.session.query.isEmpty && store.session.category == category.id
                    Button {
                        store.selectCategory(category.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: categoryIcon(for: category.id))
                                .accessibilityHidden(true)
                            Text(category.title)
                                .lineLimit(1)
                            if selected && differentiateWithoutColor {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 44)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .background(
                            Capsule()
                                .fill(selected ? Color.accentColor.opacity(0.16) : Color(uiColor: .tertiarySystemFill))
                        )
                        .overlay(
                            Capsule()
                                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.title)
                    .accessibilityValue(selected ? "已选择" : "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("unicode_emoji_category_\(category.id)")
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel("Emoji 分类")
    }

    @ViewBuilder
    private var emojiGrid: some View {
        if store.visibleItems.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: store.session.query.isEmpty ? "clock" : "magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(store.emptyStateTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("unicode_emoji_picker_empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(store.visibleItems, id: \.id) { item in
                            emojiTile(item)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    restoreFocus(with: proxy)
                }
                .onChange(of: store.session.category) { _ in
                    restoreFocus(with: proxy)
                }
                .onChange(of: store.session.query) { _ in
                    restoreFocus(with: proxy)
                }
            }
        }
    }

    private func emojiTile(_ item: EmojiCatalogItem) -> some View {
        let variants = store.variants(for: item)
        return ZStack(alignment: .bottomTrailing) {
            emojiSelectionControl(item, variants: variants)

            if variants.count > 1 {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.88)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func emojiSelectionControl(
        _ item: EmojiCatalogItem,
        variants: [EmojiCatalogItem]
    ) -> some View {
        if variants.count > 1 {
            emojiSelectionButton(item, variants: variants)
                .accessibilityAction(named: Text("选择 \(localizedName(for: item))的变体")) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    variantTarget = item
                }
        } else {
            emojiSelectionButton(item, variants: variants)
        }
    }

    private func emojiSelectionButton(
        _ item: EmojiCatalogItem,
        variants: [EmojiCatalogItem]
    ) -> some View {
        Button {
            selectItem(item)
        } label: {
            Text(item.emoji)
                .font(.system(size: min(max(26, tileSize * 0.62), 38)))
                .frame(maxWidth: .infinity, minHeight: max(44, tileSize))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .accessibilityLabel(localizedName(for: item))
        .accessibilityValue(store.isPreferred(item) ? "当前变体" : "")
        .accessibilityHint(
            variants.count > 1
                ? "双击选择；长按可选择其他变体"
                : (store.session.mode == .reaction ? "双击用此 Emoji 回应" : "双击插入此 Emoji")
        )
        .accessibilityIdentifier("unicode_emoji_\(item.id)")
        .contextMenu {
            if variants.count > 1 {
                ForEach(variants, id: \.id) { variant in
                    Button {
                        selectVariant(variant)
                    } label: {
                        Label(
                            "\(variant.emoji) \(localizedName(for: variant))",
                            systemImage: store.isPreferred(variant) ? "checkmark" : "circle"
                        )
                    }
                }
            } else {
                Button {
                    selectItem(item)
                } label: {
                    Label("选择 \(localizedName(for: item))", systemImage: "checkmark")
                }
            }
        }
    }

    private var variantDialogBinding: Binding<Bool> {
        Binding(
            get: { variantTarget != nil },
            set: { isPresented in
                if !isPresented {
                    variantTarget = nil
                }
            }
        )
    }

    private var variantDialogTitle: String {
        guard let variantTarget else { return "选择 Emoji 变体" }
        return "\(localizedName(for: variantTarget))的变体"
    }

    private func selectItem(_ item: EmojiCatalogItem) {
        let selected = store.select(item)
        onSelect(selected)
    }

    private func selectVariant(_ variant: EmojiCatalogItem) {
        let selected = store.selectVariant(variant)
        variantTarget = nil
        onSelect(selected)
    }

    private func restoreFocus(with proxy: ScrollViewProxy) {
        guard let target = restoredItemID else { return }
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo(target, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private var restoredItemID: String? {
        if store.visibleItems.contains(where: { $0.id == store.session.focusedItemID }) {
            return store.session.focusedItemID
        }
        return store.visibleItems.first?.id
    }

    private func localizedName(for item: EmojiCatalogItem) -> String {
        let zh = item.nameZhHans.trimmingCharacters(in: .whitespacesAndNewlines)
        if !zh.isEmpty { return zh }
        let localized = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty { return localized }
        let en = item.nameEn.trimmingCharacters(in: .whitespacesAndNewlines)
        return en.isEmpty ? "Emoji" : en
    }

    private func categoryIcon(for category: String) -> String {
        switch category.lowercased() {
        case "recent": return "clock"
        case "frequent": return "star"
        case "smileys & emotion", "smileys-emotion", "smileys_and_emotion": return "face.smiling"
        case "people & body", "people-body", "people_and_body": return "hand.raised"
        case "animals & nature", "animals-nature", "animals_and_nature": return "leaf"
        case "food & drink", "food-drink", "food_and_drink": return "fork.knife"
        case "travel & places", "travel-places", "travel_and_places": return "car"
        case "activities": return "sportscourt"
        case "objects": return "lightbulb"
        case "symbols": return "number"
        case "flags": return "flag"
        default: return "square.grid.2x2"
        }
    }
}

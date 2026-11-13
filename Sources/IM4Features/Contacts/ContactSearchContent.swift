// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct DebouncedContactsSearchField: View {
    let placeholder: String
    let onDraftChange: (String) -> Void
    let onEditingChange: (Bool) -> Void
    let onQueryChange: (String) -> Void
    @State private var text = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    public init(placeholder: String, onDraftChange: @escaping (String) -> Void,
                onEditingChange: @escaping (Bool) -> Void, onQueryChange: @escaping (String) -> Void) {
        self.placeholder = placeholder; self.onDraftChange = onDraftChange
        self.onEditingChange = onEditingChange; self.onQueryChange = onQueryChange
    }
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IMColor.muted)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cancelSearch()
                    } else {
                        applyQueryNow(text)
                    }
                }
                .im4ImReadableInputText()
            if !text.isEmpty {
                Button {
                    text = ""
                    onDraftChange("")
                    onQueryChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(im4Hex: 0xB7BED0))
                }
                .buttonStyle(.plain)
            }
            Button {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cancelSearch()
                } else {
                    applyQueryNow(text)
                }
            } label: {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isFocused ? "取消" : "搜索")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.brand)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(IMColor.brand.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(IMColor.line))
        )
        .im4OnChangeCompat(of: text) { _, newText in
            onDraftChange(newText)
            scheduleQueryChange(newText)
            publishEditingState()
        }
        .im4OnChangeCompat(of: isFocused) { _, _ in
            publishEditingState()
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    private func scheduleQueryChange(_ rawQuery: String) {
        debounceTask?.cancel()
        let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            onQueryChange("")
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            onQueryChange(normalizedQuery)
        }
    }

    private func applyQueryNow(_ rawQuery: String) {
        debounceTask?.cancel()
        onQueryChange(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cancelSearch() {
        debounceTask?.cancel()
        text = ""
        isFocused = false
        onDraftChange("")
        onQueryChange("")
        onEditingChange(false)
    }

    private func publishEditingState() {
        onEditingChange(isFocused || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

public enum ContactRoute: String, Identifiable, Hashable {
    case newFriends
    case groupList
    case blacklist

    public var id: String { rawValue }
}

public struct ContactEntryCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let color: Color
    var badgeCount: Int = 0

    public init(symbol: String, title: String, subtitle: String, color: Color, badgeCount: Int = 0) {
        self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.color = color; self.badgeCount = badgeCount
    }
    public var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(color.opacity(0.12)))
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(IMColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IMColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let badgeText = UnreadBadgeFormatter.text(badgeCount) {
                Text(badgeText)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, badgeText.count > 1 ? 3 : 0)
                    .background(Capsule().fill(IMColor.danger))
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                    .shadow(color: IMColor.danger.opacity(0.22), radius: 5, y: 2)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    .accessibilityLabel("\(badgeText) 个待处理好友申请")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.9))
                .shadow(color: color.opacity(0.10), radius: 16, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }
}
// WDT_IOS1_FEATURES_CONTACTS_UI_20261111_END

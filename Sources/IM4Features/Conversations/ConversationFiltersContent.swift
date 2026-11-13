// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem

public struct ConversationFiltersContent: View {
    let filters: [String]
    @Binding var filter: String
    let counts: [String: Int]

    public init(filters: [String], selection: Binding<String>, counts: [String: Int]) {
        self.filters = filters
        _filter = selection
        self.counts = counts
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(filters, id: \.self) { item in
                Button {
                    filter = item
                } label: {
                    Chip(
                        title: item,
                        isSelected: filter == item,
                        count: counts[item],
                        countColor: item == "@我" ? IMColor.danger : IMColor.brand,
                        countFilled: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation_filter_\(item)")
                .accessibilityLabel("筛选 \(item)")
            }
        }
    }

}
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

// WDT_IOS1_FEATURES_ME_UI_20261111_BEGIN
import SwiftUI
import IM4DesignSystem
import IM4Domain

public struct InboxCenterContent: View {
    @State private var selectedItem: InboxItem?
    let filteredItems: [InboxItem]
    let markRead: @MainActor (String) -> Void

    public init(items: [InboxItem], markRead: @escaping @MainActor (String) -> Void) {
        self.filteredItems = items
        self.markRead = markRead
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    SheetHeader(symbol: "tray.full.fill", title: "公告收件箱", subtitle: "只展示企业公告内容。")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("公告收件箱，只展示企业公告内容")
                    if filteredItems.isEmpty {
                        EmptyStateView(
                            symbol: "tray",
                            title: "暂无公告",
                            subtitle: "企业公告发布后会在这里展示。"
                        )
                    }
                    ForEach(filteredItems) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            InboxAnnouncementRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("公告收件箱")
        .navigationBarTitleDisplayMode(.inline)
        .im4ToolbarTabBarHiddenCompat()
        .sheet(item: $selectedItem) { item in
            AnnouncementDetailSheet(item: item)
                .im4PresentationDetentsCompat([.medium, .large])
                .im4PresentationDragIndicatorCompat(.visible)
                .onAppear {
                    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110
                    markRead(item.id)
                }
        }
    }
}
// WDT_IOS1_FEATURES_ME_UI_20261111_END

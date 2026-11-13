// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_BEGIN
import SwiftUI
import IM4Features

struct ConversationListHeaderRevision: Equatable {
    let enterprise: Enterprise
    let announcementIndex: Int
    let announcements: [InboxItem]
    let showsAnnouncements: Bool
}


struct RecycledConversationTable<Header: View, Search: View, Filter: View, Footer: View, Row: View>: View {
    let sections: ConversationRenderSections
    let rowsRevision: Int
    let displaysRows: Bool
    let searchRevision: String
    let rowContext: String
    let header: Header
    let search: Search
    let filter: Filter
    let footer: Footer
    let headerRevision: ConversationListHeaderRevision
    let filterRevision: String
    let dynamicFooter: Bool
    let interactionChanged: (Bool) -> Void
    let row: (ConversationRenderItem) -> Row
    var body: some View {
        RecycledConversationTableContent(items: sections.tableItems, rowsRevision: rowsRevision, displaysRows: displaysRows,
            searchRevision: searchRevision, rowContext: rowContext, header: header, search: search, filter: filter,
            footer: footer, headerRevision: headerRevision, filterRevision: filterRevision, dynamicFooter: dynamicFooter,
            interactionChanged: interactionChanged) { input in
                if let original = sections.itemsByID[input.id] { row(original) }
            }
    }
}
#if DEBUG
typealias ConversationListLayoutDiagnostics = IM4Features.ConversationListLayoutDiagnostics
#endif
// WDT_IOS1_FEATURES_CONVERSATIONS_UI_20261111_END

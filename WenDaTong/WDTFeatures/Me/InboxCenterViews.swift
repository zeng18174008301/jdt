import IM4Features
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct InboxCenterView: View {
    // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    let store: ContactStore
    let markRead: @MainActor (String) -> Void

    var body: some View {
        PublisherSnapshotView(initialValue: store.announcements, updates: store.announcementUpdates, content: content)
    }

    private func content(_ filteredItems: [InboxItem]) -> some View {
        // WDT_IOS1_REFACTOR_ANNOUNCEMENT_OBSERVATION_20261110_END
        InboxCenterContent(items: filteredItems, markRead: markRead)
    }
}

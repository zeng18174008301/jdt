import IM4Features
import Combine
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct DeviceSessionsView: View {
    // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_BEGIN
    let store: ContactStore
    let toggleBlocked: @MainActor (String) -> Void

    var body: some View {
        PublisherSnapshotView(
            initialValue: store.deviceSessions,
            updates: store.$deviceSessions.removeDuplicates().eraseToAnyPublisher(),
            content: content
        )
    }

    private func content(_ sessions: [DeviceSession]) -> some View {
        // WDT_IOS1_REFACTOR_CONTACT_LOCAL_OBSERVATION_20261110_END
        DeviceSessionsContent(sessions: sessions, toggleBlocked: toggleBlocked)
    }
}

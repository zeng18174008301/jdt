import IM4Features
import SwiftUI
import UIKit

struct NewFriendsView: View {
    @EnvironmentObject private var state: AppState

    // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.contactStore
        PublisherSnapshotView(
            initialValue: store.friendRequestsSnapshot, updates: store.friendRequestsUpdates, content: content
        )
    }

    private func content(_ snapshot: ContactStore.FriendRequestsSnapshot) -> some View {
        // WDT_IOS1_REFACTOR_FRIEND_REQUEST_OBSERVATION_20261110_END
        NewFriendsContent(requests: snapshot.requests) { request in
            FriendRequestRowContent(request: request, isCancelling: snapshot.isCancelling(request.id),
                onReject: { state.rejectFriendRequest(request.id) }, onAccept: { state.acceptFriendRequest(request.id) },
                onCancel: { Task { _ = await state.cancelFriendRequest(request.id) } },
                avatar: {
                    AvatarView(name: request.name, seed: 0x5D6BFF, size: 42, imageURL: request.avatarURL, certificationReference: state.certificationPillSource.reference(forExactUID: request.userID)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                }, certification: { CertificationPillView(exactUID: request.userID, compact: true) },
                onCopy: state.copyUserID)
        }
    }
}

struct BlacklistView: View {
    @EnvironmentObject private var state: AppState

    // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_BEGIN
    var body: some View {
        let store = state.contactStore
        PublisherSnapshotView(initialValue: store.blacklist, updates: store.blacklistUpdates, content: content)
    }

    private func content(_ blacklist: [BlacklistItem]) -> some View {
        // WDT_IOS1_REFACTOR_BLACKLIST_OBSERVATION_20261110_END
        BlacklistContent(blacklist: blacklist) { item in
            BlacklistRowContent(item: item, onRemove: { state.removeFromBlacklist(item.id) },
                avatar: {
                    AvatarView(name: item.name, seed: 0xFF5D73, size: 42, certificationReference: state.certificationPillSource.reference(forExactUID: item.id)) // WDT_IOS1_REFACTOR_CERTIFICATION_AVATAR_OBSERVATION_20261110
                }, certification: { CertificationPillView(exactUID: item.id, compact: true) },
                onCopy: state.copyUserID)
        }
    }
}

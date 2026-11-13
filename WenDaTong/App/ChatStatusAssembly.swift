import IM4Features
import SwiftUI

// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_BEGIN
extension ChatView {
    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_BEGIN
    @ViewBuilder
    var observedGroupAnnouncementBanner: some View {
        if conversation.kind == .group {
            let groupID = currentGroup.id
            let store = screenStores.contacts
            ChatBubbleSessionObservation(store: screenStores.tenantInteraction,
                sessionSource: screenStores.sessionIdentity, initialIdentity: screenActions.authority.chatBubbleSessionIdentity()) { binding in
            PublisherSnapshotView(
                initialValue: store.currentGroupAnnouncements[groupID],
                updates: store.currentGroupAnnouncementUpdates(groupID: groupID)
            ) { announcement in
                Group {
                    if shouldShowGroupAnnouncement {
                        assembledGroupContext(binding: binding)
                    }
                }
                .onChangeCompat(of: announcement?.id) { _, _ in
                    showGroupAnnouncement = true
                    logChatSideDataReadyIfNeeded(reason: "announcement_changed")
                }
            }
            }
        }
    }
    // WDT_IOS1_REFACTOR_GROUP_ANNOUNCEMENT_OBSERVATION_20261110_END


    func assembledGroupContext(binding: ChatBubbleSessionBinding) -> some View {
        let title = currentGroupAnnouncementTitle
        let preview = currentGroupAnnouncementPreview
        let busy = isMarkingGroupAnnouncementRead || isOpeningGroupAnnouncementDetail
        let origin = screenActions.authority.chatBubbleSessionIdentity()
        let generation = binding.generation
        let open = { performHeaderStatusAction(binding: binding, generation: generation, origin: origin, openCurrentGroupAnnouncement) }
        let close = { performHeaderStatusAction(binding: binding, generation: generation, origin: origin, closeCurrentGroupAnnouncementBanner) }
#if DEBUG
        ChatHeaderStatusDiagnostics.announcement?(ChatAnnouncementProbe(title: title, preview: preview,
            isBusy: busy, open: open, close: close, owner: self))
#endif
        return ChatGroupAnnouncementView(title: title, preview: preview, isBusy: busy, open: open, close: close)
    }

    var chatGroupMuteStatus: some View {
        ChatGroupMuteStatusView(muteBanner: disabledBannerDecision.groupMuteBanner, detail: groupMuteStatusDetail)
    }
}
// WDT_IOS1_HEADER_STATUS_BOUNDARY_20261110_END

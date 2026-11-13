import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI
import UIKit

struct PinnedMessagesSheet: View {
    @EnvironmentObject private var state: AppState
    let conversationID: String
    let onSelect: (ChatMessage) -> Void
    let onUnpin: (ChatMessage) -> Void
    var body: some View {
        state.observeChatSecondaryEntry { entry in
            ContactDirectoryPresentationView(store: state.contactStore) {
                state.conversationStore.observeConversationPresentation(id: conversationID) { conversation in
                    let messages = chatPinnedMessagesForRendering(conversation?.messages ?? [])
                    let names = Dictionary(uniqueKeysWithValues: messages.map { message in
                        let storedName = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (message.id, state.remarkPreferredDisplayName(identifiers: [message.senderId], candidates: [storedName],
                            fallback: storedName.isEmpty ? (message.senderId.isEmpty ? "未知用户" : message.senderId) : storedName))
                    })
                    PinnedMessagesContent(conversationID: conversationID,
                        onSelect: { if entry.isCurrent(state) { onSelect($0) } },
                        onUnpin: { if entry.isCurrent(state) { onUnpin($0) } }, messages: messages, senderNames: names)
                }
            }
        }
    }
}

struct GroupAnnouncementSheet: View {
    @EnvironmentObject private var state: AppState
    let group: GroupInfo
    var announcementID: String? = nil
    var onClose: (() -> Void)? = nil
    private var currentGroup: GroupInfo { state.group(id: group.id) ?? group }
    private var currentAnnouncement: GroupAnnouncement? { state.contactStore.groupAnnouncement(groupID: group.id, announcementID: announcementID) }
    var body: some View {
        let store = state.contactStore
        return state.observeChatSecondaryEntry { entry in
            GroupSnapshotView(store: store, groupID: group.id) {
                PublisherSnapshotView(initialValue: currentAnnouncement,
                    updates: store.groupAnnouncementUpdates(groupID: group.id, announcementID: announcementID)) { _ in
                    assembledContent(entry: entry)
                }
            }
        }
    }
    private func assembledContent(entry: ChatSecondaryEntry) -> some View {
        let original = currentAnnouncement
        let actions = ChatAnnouncementActions(load: {
            guard entry.isCurrent(state) else { return }
            state.loadGroupDetailIfNeeded(groupID: group.id, force: true)
            if let announcementID = currentAnnouncement?.id {
                state.loadGroupAnnouncementDetail(groupID: group.id, announcementID: announcementID)
            }
        }, reload: { id in
            // Completion of an already admitted publish keeps the original reload contract.
            state.loadGroupAnnouncementDetail(groupID: group.id, announcementID: id)
        }, copy: { content in
            guard entry.isCurrent(state) else { return }
            UIPasteboard.general.string = content
            state.setToast("群公告已复制")
        }, emptyContent: {
            if entry.isCurrent(state) { state.setToast("请输入公告内容") }
        }, publish: { title, content, completion in
            guard entry.isCurrent(state) else { return false }
            state.saveGroupAnnouncement(groupID: group.id, announcementID: original?.id,
                expectedUpdatedAt: original?.updatedAt, title: title, content: content, completion: completion)
            return true
        })
        return GroupAnnouncementContent(group: group, announcementID: announcementID, onClose: onClose,
            currentGroup: currentGroup, currentAnnouncement: currentAnnouncement,
            canPublish: state.canManageGroup(currentGroup), actions: actions)
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

// WDT_IOS1_PINNED_CONTEXT_VALUE_BOUNDARY_20261111_BEGIN
extension ChatView {
    func pinnedContext(messages: [ChatMessage]) -> some View {
        let activeMessage = messages.isEmpty ? nil : messages[pinnedCarouselIndex % messages.count]
        let input = ChatPinnedContextInput(text: activeMessage?.text ?? "置顶消息",
            positionText: messages.count > 1 ? "\((pinnedCarouselIndex % messages.count) + 1)/\(messages.count)" : nil)
        return ChatPinnedContextView(input: input, open: { showPinnedMessages = true })
    }
}
// WDT_IOS1_PINNED_CONTEXT_VALUE_BOUNDARY_20261111_END

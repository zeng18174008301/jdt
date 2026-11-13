import IM4Features
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_BEGIN
import SwiftUI

struct ReadReceiptSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var observedCurrentUser: IMUser?
    let message: ChatMessage
    let conversation: ConversationMessageSnapshot
    let readReceiptsEnabled: Bool
    private var renderedCurrentUser: IMUser { observedCurrentUser ?? state.currentUser }
    var body: some View {
        state.tenantClientPolicyStore.observe(\.showsGroupMemberCount) { _ in
            ContactDirectoryPresentationView(store: state.contactStore) { receiptAuthorityContent }
        }
        .onReceive(state.currentUserPresentationStore.updates(on: CurrentUserPresentationStore.display)) { user in
            if observedCurrentUser != user { observedCurrentUser = user }
        }
    }
    @ViewBuilder private var receiptAuthorityContent: some View {
        if conversation.kind == .group {
            let store = state.readReceiptAuthorityStore
            PublisherSnapshotView(initialValue: store[conversation.id], updates: store.updates(for: conversation.id)) { _ in
                receiptContent
            }
        } else { receiptContent }
    }
    private var receiptContent: some View {
        let peer = conversation.participants.first { $0.id != message.senderId } ?? conversation.participants.first
        let users = message.readBy.map(\.user) + message.unreadBy.map(\.user) + message.reactionDetails.map(\.user)
        let readBy = message.readBy.map { receipt in
            ChatReadReceiptPresentation(receipt: receipt,
                displayName: state.remarkPreferredDisplayName(for: receipt.user, fallback: "未知用户"))
        }
        let unreadBy = message.unreadBy.map { receipt in
            ChatReadReceiptPresentation(receipt: receipt,
                displayName: state.remarkPreferredDisplayName(for: receipt.user, fallback: "未知用户"))
        }
        let reactionDetails = message.reactionDetails.map { reaction in
            ChatReactionDetailPresentation(reaction: reaction,
                displayName: state.remarkPreferredDisplayName(for: reaction.user, fallback: "未知用户"))
        }
        let ids = Set(users.map(\.id) + [renderedCurrentUser.id, peer?.id ?? ""])
        let certifications = Dictionary(uniqueKeysWithValues: ids.compactMap { uid in
            state.certificationPillSource.reference(forExactUID: uid).map { (uid, $0) }
        })
        let input = ChatReceiptInput(currentUser: renderedCurrentUser,
            canViewDetails: state.canViewMessageReadDetails(message, in: conversation),
            showsGroupMemberCount: state.shouldShowGroupMemberCount,
            peerDisplayName: peer.map { state.remarkPreferredDisplayName(for: $0, fallback: "对方") } ?? "对方",
            readBy: readBy, unreadBy: unreadBy, reactionDetails: reactionDetails, certifications: certifications.mapValues(\.chatFeatureReference))
#if DEBUG
        ChatSecondaryRenderingDiagnostics.receipt?(input)
#endif
        return ReadReceiptContent(input: input, message: message, conversation: conversation, readReceiptsEnabled: readReceiptsEnabled)
    }
}
// WDT_IOS1_REFACTOR_SECONDARY_CHAT_SURFACES_20261110_END

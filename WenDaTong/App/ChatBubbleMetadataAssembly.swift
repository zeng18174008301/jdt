import IM4Features
import SwiftUI
import IM4Stores // WDT_IOS1_STORES_CONTACT_ACTUAL_20261110

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
struct ContactCardBubbleContent: View {
    @Environment(\.enterpriseDisplayName) private var enterpriseDisplayName // WDT_IOS1_REFACTOR_ENTERPRISE_MEMBERSHIP_OBSERVATION_20261110
    @EnvironmentObject private var state: AppState
    @Environment(\.contactDirectoryPresentation) private var directory // WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110
    let message: ChatMessage
    let outgoing: Bool
    var onOpen: (IMUser) -> Void

    // WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_BEGIN
    var body: some View {
        ContactCardPresentationContent(
            message: message,
            contacts: directory?.contacts ?? state.contacts,
            enterpriseName: enterpriseDisplayName ?? state.currentEnterprise.name,
            outgoing: outgoing,
            onOpen: onOpen
        )
    }
    // WDT_IOS1_CHAT_CONTACT_CARD_FEATURE_PROJECTION_20261111_END
}

// WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_BEGIN
struct ChatCallRecordBubbleContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.contactDirectoryPresentation) private var directory
    @Environment(\.chatCallRecordConversation) private var transcriptConversation // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110
    let record: RTCCallRecordPayload
    let conversationID: String
    let viewerIsCaller: Bool
    let outgoing: Bool
    let onRedial: () -> Void

    private var peerName: String {
        let conversation = transcriptConversation ?? state.conversation(id: conversationID) // WDT_IOS1_REFACTOR_TRANSCRIPT_CONVERSATION_INPUTS_20261110
        if let peer = state.directConversationCallPeer(for: conversation, directoryContacts: directory?.contacts) {
            return state.remarkPreferredDisplayName(for: peer, fallback: conversation.title, directory: directory)
        }
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "对方" : title
    }

    var body: some View {
        RTCCallRecordCard(
            record: record,
            viewerIsCaller: viewerIsCaller,
            peerName: peerName,
            outgoing: outgoing,
            onRedial: onRedial
        )
    }
}
// WDT_IOS1_REFACTOR_TRANSCRIPT_CONTACT_PRESENTATION_20261110_END

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END

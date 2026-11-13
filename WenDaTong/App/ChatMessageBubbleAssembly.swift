import IM4Features
import Combine
import SwiftUI
import UIKit

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN

// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
@MainActor
struct ChatBubbleRowActions {
    let onSelectionTap: (() -> Void)?
    let onLongPress: () -> Void
    let onReadTap: () -> Void
    let onSenderTap: (IMUser) -> Void
    let onContactCardTap: (IMUser) -> Void
    let onMentionTap: (IMUser) -> Void
    let onAttachmentTap: (ChatMessage) -> Void
    let onCurrentUserTap: () -> Void
    let onResend: () -> Void
    let onReviewInvite: (GroupInviteApproval, Bool) -> Void
    let onCopy: (String) -> Void
    let onRedial: (RTCCallRecordPayload) -> Void

    func guarded(by isCurrent: @escaping () -> Bool) -> Self {
        Self(
            onSelectionTap: onSelectionTap.map { action in { if isCurrent() { action() } } },
            onLongPress: { if isCurrent() { onLongPress() } },
            onReadTap: { if isCurrent() { onReadTap() } },
            onSenderTap: { user in if isCurrent() { onSenderTap(user) } },
            onContactCardTap: { user in if isCurrent() { onContactCardTap(user) } },
            onMentionTap: { user in if isCurrent() { onMentionTap(user) } },
            onAttachmentTap: { message in if isCurrent() { onAttachmentTap(message) } },
            onCurrentUserTap: { if isCurrent() { onCurrentUserTap() } },
            onResend: { if isCurrent() { onResend() } },
            onReviewInvite: { approval, approve in if isCurrent() { onReviewInvite(approval, approve) } },
            onCopy: { value in if isCurrent() { onCopy(value) } },
            onRedial: { record in if isCurrent() { onRedial(record) } }
        )
    }
}

struct ChatBubbleInviteProcessing {
    let initialValue: Bool
    let updates: AnyPublisher<Bool, Never>
}

struct MessageBubble: View { // WDT_IOS1_REFACTOR_TIMELINE_INCREMENTAL_RENDER_20261110
    let rowModel: MessageRowModel
    let conversationID: String
    let isGroupConversation: Bool
    let isBatchSelected: Bool
    let presentation: MessageBubblePresentation
    let actions: ChatBubbleRowActions
    let inviteProcessing: ChatBubbleInviteProcessing?

    var message: ChatMessage { rowModel.message }
    var onSelectionTap: (() -> Void)? { actions.onSelectionTap }

    private var isBubbleOutgoing: Bool { message.kind != .system && message.isOutgoing }

    private var hasSpecialContent: Bool {
        message.groupInviteApproval != nil || message.rtcCallRecord != nil || message.isStickerMessage
            || message.kind == .voice || message.kind == .file || message.kind == .image
            || message.kind == .video || message.kind == .contactCard
    }

    var body: some View {
#if DEBUG
        let _ = ChatTimelineRenderDiagnostics.batchForwardBubble?(self) // WDT_IOS1_BATCH_FORWARD_LIVE_SOURCE_20261110
        let _ = ChatBubbleAssemblyDiagnostics.capture?(ChatBubbleAssemblyProbe(
            messageID: message.id, presentation: presentation,
            onReadTap: actions.onReadTap, onSenderTap: actions.onSenderTap,
            onCurrentUserTap: actions.onCurrentUserTap, onLongPress: actions.onLongPress,
            onAttachmentTap: actions.onAttachmentTap, onResend: actions.onResend
        ))
#endif
        let content = MessageBubbleContent(
            message: message, conversationID: conversationID, showsSenderHeader: rowModel.showsSenderHeader,
            isGroupConversation: isGroupConversation, isBatchSelected: isBatchSelected,
            onSelectionTap: onSelectionTap, onLongPress: actions.onLongPress, onReadTap: actions.onReadTap,
            onSenderTap: actions.onSenderTap, onContactCardTap: actions.onContactCardTap,
            onMentionTap: actions.onMentionTap, onAttachmentTap: actions.onAttachmentTap,
            onCurrentUserTap: actions.onCurrentUserTap, onResend: actions.onResend,
            rowModel: rowModel, presentation: presentation, hasSpecialContent: hasSpecialContent,
            specialContent: { specialContent },
            replyContent: { TranscriptReplyQuote(message: message, conversationID: conversationID, outgoing: isBubbleOutgoing) }
        )
#if DEBUG
        return content.observingBodyEvaluation { conversation, message in
            ChatTimelineRenderDiagnostics.recordBubbleBody(conversationID: conversation, message: message)
        }.equatable()
#else
        return content.equatable()
#endif
    }

    @ViewBuilder private var specialContent: some View {
        if let approval = message.groupInviteApproval, let inviteProcessing {
            PublisherSnapshotView(initialValue: inviteProcessing.initialValue, updates: inviteProcessing.updates) { isProcessing in
                GroupInviteApprovalCard(
                    approval: approval, compact: true, isProcessing: isProcessing,
                    onReview: { actions.onReviewInvite(approval, $0) },
                    onCopy: { value in actions.onCopy(value) }
                )
            }.id(approval.requestID)
        } else if let record = message.rtcCallRecord {
            ChatCallRecordBubbleContent(
                record: record, conversationID: conversationID,
                viewerIsCaller: message.isOutgoing, outgoing: isBubbleOutgoing
            ) {
                if let onSelectionTap { onSelectionTap() }
                else { actions.onRedial(record) }
            }
        } else if message.isStickerMessage {
            StickerMessageView(message: message)
        } else if message.kind == .voice {
            VoiceBubbleContent(message: message, outgoing: isBubbleOutgoing, conversationID: conversationID)
        } else if message.kind == .file || message.kind == .image || message.kind == .video {
            FileBubbleContent(message: message, outgoing: isBubbleOutgoing, conversationID: conversationID)
        } else if message.kind == .contactCard {
            ContactCardBubbleContent(message: message, outgoing: isBubbleOutgoing) { user in
                actions.onContactCardTap(user)
            }
        }
    }
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END

#if DEBUG
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_BEGIN
struct ChatBubbleAssemblyProbe {
    let messageID: String
    let presentation: MessageBubblePresentation
    let onReadTap: () -> Void
    let onSenderTap: (IMUser) -> Void
    let onCurrentUserTap: () -> Void
    let onLongPress: () -> Void
    let onAttachmentTap: (ChatMessage) -> Void
    // WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
    let onResend: () -> Void
    // WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END
}
// WDT_IOS1_CHAT_BUBBLE_APP_LEAF_20261111_END
@MainActor enum ChatBubbleAssemblyDiagnostics {
    static var capture: ((ChatBubbleAssemblyProbe) -> Void)?
}
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END
#endif

// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_BEGIN
// Retained actions retain this subscription too, so A -> logged-out -> A cannot revive them.
// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_BEGIN
@MainActor final class ChatBubbleSessionBinding: ObservableObject {
    // Retirement is still scope/login-only; identity observation does not advance this value.
    @Published private(set) var generation = UUID()
    @Published private(set) var sessionIdentity: ChatBubbleSessionIdentity
    private var observation: AnyCancellable?
    private var sessionObservation: AnyCancellable?

    init(store: TenantInteractionPresentationStore,
         sessionSource: ChatBubbleSessionIdentitySource, initialIdentity: ChatBubbleSessionIdentity) {
        sessionIdentity = initialIdentity
        observation = store.updates(\.activeScope).dropFirst().sink { [weak self] _ in
            self?.generation = UUID()
        }
        sessionObservation = sessionSource.updates.sink { [weak self] current in
            guard let self, self.sessionIdentity != current else { return }
            self.sessionIdentity = current
        }
    }
}

// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_BEGIN
struct ChatBubbleSessionObservation<Content: View>: View {
    @StateObject private var binding: ChatBubbleSessionBinding
    let content: (ChatBubbleSessionBinding) -> Content

    init(store: TenantInteractionPresentationStore, sessionSource: ChatBubbleSessionIdentitySource,
         initialIdentity: ChatBubbleSessionIdentity, @ViewBuilder content: @escaping (ChatBubbleSessionBinding) -> Content) {
        _binding = StateObject(wrappedValue: ChatBubbleSessionBinding(
            store: store, sessionSource: sessionSource, initialIdentity: initialIdentity))
        self.content = content
    }

    var body: some View { content(binding) }
}
// WDT_IOS1_REFACTOR_REPLY_VOICE_MEDIA_BOUNDARY_20261110_END
// WDT_IOS1_CHAT_F4_SESSION_IDENTITY_OBSERVATION_20261110_END
// WDT_IOS1_REFACTOR_BUBBLE_PRESENTATION_BOUNDARY_20261110_END

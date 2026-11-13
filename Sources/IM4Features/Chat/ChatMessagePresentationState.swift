import SwiftUI
import IM4Domain

// WDT_IOS1_CHAT_STATE_20261023_BEGIN
// Each ChatView owns its state; no global message retention or cross-conversation sharing.
@MainActor
final public class ChatMessagePresentationState: ObservableObject {
    @Published public var actionMessage: ChatMessage?
    @Published public var reactionMessage: ChatMessage?
    @Published public var receiptMessage: ChatMessage?
    @Published public var editMessage: ChatMessage?
    @Published public var reportMessage: ChatMessage?
    @Published public var adminDeleteCandidate: ChatMessage?
    @Published public var failedDeleteCandidate: ChatMessage?
    @Published public var pendingPinnedJumpMessage: ChatMessage?
    @Published public var selectedAttachmentMessage: ChatMessage?

    public init() {}
}
// WDT_IOS1_CHAT_STATE_20261023_END
